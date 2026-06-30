# frozen_string_literal: true

module Truffle
  # A stateful agent: a provider, a system prompt, a running message history,
  # and a toolbox. Calling #run drives the agent loop to completion.
  #
  # The loop is the port of pi's agent-core runtime:
  #
  #   run(text)
  #     emit :agent_start
  #     append user message
  #     loop:
  #       emit :turn_start
  #       response = provider.chat(messages, tools)
  #       append assistant message; emit :message
  #       if response has tool calls:
  #         preflight calls, run allowed tools in parallel by default, append
  #         tool-result messages in assistant order
  #         emit :turn_end ; continue   # feed results back to the model
  #       else:
  #         emit :turn_end ; emit :agent_end ; return assistant text
  #
  # Events let a UI (TUI, web, logs) observe the run without the harness
  # knowing anything about how it is rendered. Subscribe with #on.
  #
  # When built with a session, the agent is session-backed: every message it
  # appends to its running history is also appended to the session, and the loop
  # auto-compacts. At the top of each turn, if the previous turn's reported usage
  # has crossed the model's compaction threshold, the agent summarizes the older
  # turns into a session compaction entry and rebuilds its context from it before
  # calling the provider, so a long run stays under the model's window. This is
  # the port of pi's _checkCompaction/_runAutoCompaction, checked at the same
  # boundary pi checks (after an assistant turn, before the next provider call).
  #
  # A session-backed agent also recovers from context overflow: when a turn fails
  # (or silently degrades) because the prompt exceeded the model's window, the
  # agent compacts and, if the failed turn can be retried, drops it and runs the
  # turn again on the smaller context. Recovery is attempted once per overflow; a
  # second consecutive overflow ends the run rather than looping.
  #
  # Any agent (session-backed or not) also auto-retries a turn that failed with a
  # transient provider or transport error: a load spike, a 5xx, a throttle, a
  # dropped socket. When the Retry classifier deems a failed turn transient (and
  # it is not a context overflow, which the compactor owns), the agent drops the
  # failed turn, waits out an exponential backoff, and runs the turn again, up to
  # a retry budget. The counter resets on the next turn that is not retried, so
  # each fresh failure gets the full budget. Port of pi's _prepareRetry.
  class Agent
    DEFAULT_MAX_TURNS = 12

    EVENTS = %i[agent_start turn_start message tool_call tool_result turn_end
                agent_end compaction retry].freeze

    # Auto-retry defaults, ported from pi's getRetrySettings plus its provider
    # retry-delay cap: retry up to three times with exponential backoff from a 2s
    # base, and cap any server-requested delay at 60s. A caller tunes or disables
    # this with retry_settings: at construction.
    DEFAULT_RETRY_SETTINGS = {
      enabled: true,
      max_retries: 3,
      base_delay_ms: 2000,
      max_delay_ms: 60_000
    }.freeze
    TOOL_EXECUTION_MODES = %i[parallel sequential].freeze

    attr_reader :provider, :messages, :toolbox, :system_prompt, :max_turns,
                :usage, :session, :tool_execution

    # Resume an agent from a session file. The session carries the conversation
    # and, when it was dumped by #dump, the model and the names of the tools the
    # agent had. The caller re-supplies the live pieces that cannot be serialized:
    # the provider, the actual tool implementations, and the system prompt (pi
    # regenerates the system prompt from config rather than storing it, so it is
    # configuration here too). Tools are rebound by name: every tool the dumped
    # agent had must be present in `tools`, or load raises. The model defaults to
    # the one recorded in the session; pass model: to override it.
    def self.load(path, provider:, tools: [], system_prompt: nil, model: nil,
                  max_turns: DEFAULT_MAX_TURNS, tool_execution: :parallel,
                  prompt_templates: [], slash_commands: nil)
      session = Session.load(path)
      toolbox = rebind_toolbox(session.tools, tools)
      context = session.context
      agent = new(provider: provider, system_prompt: system_prompt, tools: toolbox,
                  model: model || context.model&.model_id, max_turns: max_turns,
                  tool_execution: tool_execution, prompt_templates: prompt_templates,
                  slash_commands: slash_commands)
      agent.restore(context.messages)
    end

    # Build the toolbox a resumed agent runs with, checking that every tool the
    # dumped agent relied on is among the ones supplied now. The session stores
    # only names; the implementations are rebound here. A required tool that was
    # not supplied is an error, not a silent gap, since the model may call it.
    def self.rebind_toolbox(required_names, supplied)
      toolbox = supplied.is_a?(Toolbox) ? supplied : Toolbox.new(supplied)
      missing = Array(required_names) - toolbox.names
      unless missing.empty?
        raise Error, "session needs tool(s) not supplied to load: #{missing.join(", ")}"
      end

      toolbox
    end
    private_class_method :rebind_toolbox

    # session, when given, makes the agent session-backed: appended messages are
    # mirrored into it and the run auto-compacts against the model's window. The
    # running history is seeded from the session's context (its compaction
    # summary plus kept tail when it was already compacted), so a resumed session
    # picks up where it left off. compaction_settings tunes the threshold and
    # retention budget; auto_compact: false keeps a session-backed agent from
    # ever compacting (the session is still mirrored).
    def initialize(provider:, system_prompt: nil, tools: [], model: nil,
                   max_turns: DEFAULT_MAX_TURNS, session: nil,
                   compaction_settings: Compaction::DEFAULT_SETTINGS, auto_compact: true,
                   retry_settings: DEFAULT_RETRY_SETTINGS,
                   before_tool_call: nil, after_tool_call: nil,
                   tool_execution: :parallel,
                   prompt_templates: [], slash_commands: nil)
      @provider = provider
      @system_prompt = system_prompt
      @model = model
      @max_turns = max_turns
      @toolbox = tools.is_a?(Toolbox) ? tools : Toolbox.new(tools)
      @listeners = Hash.new { |h, k| h[k] = [] }
      @session = session
      @compaction_settings = compaction_settings
      @auto_compact = auto_compact
      @retry_settings = DEFAULT_RETRY_SETTINGS.merge(retry_settings || {})
      @tool_execution = normalize_tool_execution(tool_execution)
      @slash_commands = slash_commands || slash_registry_for(prompt_templates)
      # Optional tool-execution middleware, ported from pi's beforeToolCall /
      # afterToolCall seam. Each is a callable handed a single context Hash. The
      # before hook can veto a call ({ block: true }); the after hook can override
      # the executed result ({ result: ... }). See #execute for the contract.
      @before_tool_call = before_tool_call
      @after_tool_call = after_tool_call
      # How many times the current run has restarted a turn the Retry classifier
      # deemed transient. Reset to zero at the start of each run and after any turn
      # that is not retried, so each fresh failure gets the full retry budget.
      @retry_attempt = 0
      # The context tokens the last provider response reported, the input to the
      # compaction threshold at the top of the next turn. Nil until the first
      # response, and cleared once a usage reading has triggered a compaction so
      # the same reading cannot trigger another.
      @last_usage = nil
      # Whether the current overflow situation has already had its one
      # compact-and-retry attempt. Reset at the start of each run and after any
      # turn that did not overflow, so each distinct overflow gets one recovery.
      @overflow_recovery_attempted = false

      @messages = []
      @messages << Message.system(system_prompt) if system_prompt
      @messages.concat(@session.context.messages) if @session
      # Token usage and cost accumulated across every turn of every run on this
      # agent, the way pi tallies a session. #reset clears it.
      @usage = Usage.zero
    end

    # Register a listener. `on(:tool_call) { |payload| ... }` for one event, or
    # `on { |type, payload| ... }` (no event arg) for every event.
    def on(event = nil, &block)
      raise ArgumentError, "on requires a block" unless block

      if event.nil?
        @listeners[:_all] << block
      else
        event = event.to_sym
        unless EVENTS.include?(event)
          raise ArgumentError, "unknown event #{event.inspect}, expected one of #{EVENTS.inspect}"
        end

        @listeners[event] << block
      end
      self
    end

    # Send a user message and run the loop until the model answers without
    # requesting a tool. Returns the final assistant text.
    #
    # Pass signal: a Truffle::AbortSignal to cancel a long run. It is checked at
    # turn boundaries (before each provider call, which is also the point reached
    # after a batch of tool calls), so an abort stops the loop mid-flight and
    # ends with a StopReason::ABORTED terminal rather than starting another turn.
    # Cancellation is cooperative: an in-progress provider call still finishes.
    def run(user_input, signal: nil)
      command_result = resolve_slash_command(user_input)
      return run_slash_action(command_result) if command_result&.type == :action

      user_input = command_result.content if command_result&.type == :prompt
      emit(:agent_start, input: user_input)
      append(Message.user(user_input))
      @overflow_recovery_attempted = false
      @retry_attempt = 0

      final_text = nil
      final_response = nil
      aborted = false
      turns = 0

      loop do
        if signal&.aborted?
          aborted = true
          break
        end

        maybe_compact(signal)

        turns += 1
        raise Error, "exceeded max_turns (#{max_turns}) without a final answer" if turns > max_turns

        emit(:turn_start, turn: turns)
        response = @provider.chat(messages: @messages, tools: @toolbox.to_schema, model: @model)
        final_response = response
        append(response.message)
        @usage += response.usage
        @last_usage = response.usage
        emit(:message, message: response.message, usage: response.usage)

        next if handle_recovery(response, signal) == :retry

        unless response.tool_calls?
          final_text = response.text
          emit(:turn_end, turn: turns, tool_results: [])
          break
        end

        tool_results = run_tool_calls(response.tool_calls)
        emit(:turn_end, turn: turns, tool_results: tool_results)
      end

      # On a clean finish, final_response is the turn that ended the loop (the
      # model answered without asking for a tool), so its stop reason carries.
      # On an abort there is no clean final answer, so the run's reason is
      # :aborted and any partial output stays available on `messages`.
      stop_reason = aborted ? StopReason::ABORTED : final_response&.stop_reason
      error_message = aborted ? nil : final_response&.error_message
      emit(:agent_end, output: final_text, messages: @messages,
                       stop_reason: stop_reason,
                       error_message: error_message,
                       usage: @usage)
      final_text
    end

    # Reset history back to just the system prompt (keeps tools + listeners) and
    # clear the accumulated usage.
    def reset
      @messages = []
      @messages << Message.system(@system_prompt) if @system_prompt
      @usage = Usage.zero
      self
    end

    # Write this agent's state to a new session file under `dir` and return the
    # Session. The conversation is persisted (the system prompt is left out, since
    # it is regenerated from config on resume, as in pi); the model is recorded as
    # a model_change so a resumed session restarts on it; and the toolbox names go
    # in the header so Agent.load can rebind the tools by name. cwd is metadata
    # only, the working directory the session belongs to.
    def dump(dir:, cwd: Dir.pwd)
      session = Session.create(dir: dir, cwd: cwd, tools: @toolbox.names)
      session.append_model_change(provider: @provider.name, model_id: @model) if @model
      conversation.each { |message| session.append_message(message) }
      session.flush
      session
    end

    # Replace the running history with a restored conversation, keeping the
    # system prompt at the front. Used by Agent.load to resume a session; the
    # restored messages are the user/assistant/tool turns, never a system message.
    def restore(messages)
      reset
      @messages.concat(messages)
      self
    end

    private

    # Add a message to the running history and, when the agent is session-backed,
    # mirror it into the session so the on-disk branch stays in lockstep with the
    # context the model sees. The system prompt is never appended here, so the
    # session holds only the conversation, the way pi's session does.
    def append(message)
      @messages << message
      @session&.append_message(message)
    end

    # Before a turn, summarize older history into a session compaction entry when
    # the last response's reported context has crossed the model's threshold, then
    # rebuild the running context from the session so the turn runs under the
    # window. A no-op unless the agent is session-backed, auto-compaction is on, a
    # usage reading exists, and the model is one the catalog can size. The reading
    # is cleared before compacting so a single reading triggers at most one
    # compaction. Port of pi's threshold branch of _checkCompaction.
    def maybe_compact(signal)
      return unless @auto_compact && @session && @last_usage

      model = @model && Models.find(@model)
      return unless model

      context_tokens = Compaction.calculate_context_tokens(@last_usage)
      return unless Compaction.should_compact?(context_tokens, model.context_window,
                                               @compaction_settings)

      @last_usage = nil
      run_compaction(model, signal)
    end

    # Compact the session's branch: prepare a cut, summarize the dropped history
    # through the provider, append the compaction entry, and rebuild the running
    # context from it. Returns true when a compaction entry was written, false on
    # a no-op (an empty branch or one already ending in a compaction) or when a
    # Compaction::Error (aborted or a summarizer failure) ends compaction without
    # touching the session, leaving the turn on the un-compacted context. The
    # boolean lets overflow recovery decide whether a retry is worth attempting:
    # retrying without having shrunk the context would just overflow again. Port
    # of pi's _runAutoCompaction.
    def run_compaction(model, signal)
      preparation = Compaction.prepare_compaction(@session.entries, @compaction_settings)
      return false unless preparation

      result = Compaction.compact(preparation, @provider, model, signal: signal)
      @session.append_compaction(
        summary: result.summary, first_kept_entry_id: result.first_kept_entry_id,
        tokens_before: result.tokens_before, details: result.details
      )
      rebuild_messages_from_session
      emit(:compaction, result: result)
      true
    rescue Compaction::Error => e
      emit(:compaction, result: nil, error: e)
      false
    end

    # After a turn, run the two recovery checks in order and report whether the
    # loop should restart the turn. Context overflow is the compactor's job and is
    # checked first; a transient provider or transport error is the retry policy's
    # and is checked second. Either may ask for a restart (:retry); otherwise the
    # turn proceeds (:continue). Each check, when it declines, resets its own
    # one-shot gate so the next distinct failure starts fresh.
    def handle_recovery(response, signal)
      case maybe_recover_from_overflow(response, signal)
      when :retry then return :retry
      when :none then @overflow_recovery_attempted = false
      end

      case maybe_retry(response, signal)
      when :retry then return :retry
      when :none then @retry_attempt = 0
      end

      :continue
    end

    # After a turn, decide whether it overflowed the context window and what to do
    # about it. Returns :retry when the turn was compacted away and the loop should
    # run the turn again on the smaller context; :none when the turn did not
    # overflow (the caller clears the recovery gate); and :done or :exhausted when
    # the run should end on this turn. Port of pi's overflow branch of
    # _checkCompaction.
    #
    # The three end states mirror pi:
    #   - A completed answer that still overran the window (:done): compact so a
    #     future prompt starts clean, but the answer is finished, so do not retry.
    #   - A retryable overflow (an error or a length stop) on the first attempt:
    #     compact, drop the failed turn from the live context, and retry once.
    #   - The same overflow a second time, or one that could not be compacted away
    #     (:exhausted): give up rather than loop, and let the failed turn end the
    #     run.
    def maybe_recover_from_overflow(response, signal)
      model = @auto_compact && @session && @model && Models.find(@model)
      return :none unless model
      return :none unless Overflow.context_overflow?(response, context_window: model.context_window)

      return overflow_compact_only(model, signal) if response.stop_reason == StopReason::STOP

      overflow_retry(model, signal)
    end

    # A successful answer that overran the window: compact for the next prompt,
    # but the turn is complete and an assistant answer cannot be continued, so the
    # run ends here.
    def overflow_compact_only(model, signal)
      run_compaction(model, signal)
      :done
    end

    # A retryable overflow (an error or length-truncated turn). The first time,
    # compact and retry once; drop the failed turn from the live context (it stays
    # in the session for history) so the retry runs on the compacted messages
    # alone. A second consecutive overflow, or one that could not be compacted, is
    # unrecoverable.
    def overflow_retry(model, signal)
      if @overflow_recovery_attempted
        emit(:compaction, result: nil, error: Compaction::Error.new(
          :overflow_unrecovered,
          "context overflow recovery failed after one compact-and-retry attempt"
        ))
        return :exhausted
      end

      @overflow_recovery_attempted = true
      return :exhausted unless run_compaction(model, signal)

      @messages.pop if @messages.last&.role == :assistant
      @last_usage = nil
      :retry
    end

    # After a turn, decide whether it failed with a transient provider or
    # transport error worth restarting. Returns :retry when the turn was dropped
    # and the loop should run it again after a backoff, and :none otherwise (a
    # clean turn, a non-retryable error, or a spent retry budget). Port of pi's
    # _isRetryableError gate plus _prepareRetry: classify, count against the
    # budget, back off, drop the failed turn from the live context, and retry.
    #
    # A turn that overflowed the context window is not retried here: overflow is
    # the compactor's job (handled just above), so a retry would only refail. The
    # failed turn is removed from the live messages but stays in the session for
    # history, the way pi keeps the error in the session while dropping it from
    # the context the next call sees.
    def maybe_retry(response, signal)
      return :none unless @retry_settings[:enabled]
      return :none unless retryable_error?(response)

      @retry_attempt += 1
      if @retry_attempt > @retry_settings[:max_retries]
        # The budget is spent. Step the counter back so it reads as the number of
        # attempts actually made, and let the failed turn end the run.
        @retry_attempt -= 1
        return :none
      end

      delay_ms = retry_delay_ms(response)
      emit(:retry, attempt: @retry_attempt, max_retries: @retry_settings[:max_retries],
                   delay_ms: delay_ms, error_message: response.error_message)
      backoff(delay_ms, signal)

      @messages.pop if @messages.last&.role == :assistant
      @last_usage = nil
      :retry
    end

    def retry_delay_ms(response)
      delay_ms = response.retry_after_ms ||
                 (@retry_settings[:base_delay_ms] * (2**(@retry_attempt - 1)))
      max_delay_ms = @retry_settings[:max_delay_ms]
      return delay_ms if max_delay_ms.nil? || max_delay_ms <= 0

      [delay_ms, max_delay_ms].min
    end

    # Whether a failed turn reads as a transient, retryable error and is not a
    # context overflow. Overflow is excluded because the compactor owns it; the
    # window comes from the catalog when the model is known (an error-phrase
    # overflow is caught without one). Mirrors pi's _isRetryableError.
    def retryable_error?(response)
      window = (@model && Models.find(@model))&.context_window
      return false if Overflow.context_overflow?(response, context_window: window)

      Retry.retryable_assistant_error?(response)
    end

    # Wait out the backoff before a retry. The sleep is skipped when the delay is
    # zero (a caller that tuned it away, or a test) or the run has been aborted,
    # since the loop's top-of-turn abort check ends the run cleanly on the next
    # pass rather than sleeping first.
    def backoff(delay_ms, signal)
      return if delay_ms <= 0 || signal&.aborted?

      sleep(delay_ms / 1000.0)
    end

    # Replace the running history with the session's current context (compaction
    # summary plus kept tail), keeping the system prompt at the front. Unlike
    # #restore this leaves the accumulated usage alone, since a compaction happens
    # mid-run and the run's cost tally must carry across it.
    def rebuild_messages_from_session
      @messages = []
      @messages << Message.system(@system_prompt) if @system_prompt
      @messages.concat(@session.context.messages)
    end

    # The turns to persist: the history without the system prompt, which is
    # configuration re-supplied on resume rather than part of the conversation.
    def conversation
      @messages.reject { |message| message.role == :system }
    end

    def emit(event, **payload)
      @listeners[event].each { |l| l.call(payload) }
      @listeners[:_all].each { |l| l.call(event, payload) }
    end
  end
end
