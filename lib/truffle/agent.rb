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
  #         for each call: emit :tool_call, run tool, append tool result,
  #                        emit :tool_result
  #         emit :turn_end ; continue   # feed results back to the model
  #       else:
  #         emit :turn_end ; emit :agent_end ; return assistant text
  #
  # Events let a UI (TUI, web, logs) observe the run without the harness
  # knowing anything about how it is rendered. Subscribe with #on.
  class Agent
    DEFAULT_MAX_TURNS = 12

    EVENTS = %i[agent_start turn_start message tool_call tool_result turn_end agent_end].freeze

    attr_reader :provider, :messages, :toolbox, :system_prompt, :max_turns, :usage

    # Resume an agent from a session file. The session carries the conversation
    # and, when it was dumped by #dump, the model and the names of the tools the
    # agent had. The caller re-supplies the live pieces that cannot be serialized:
    # the provider, the actual tool implementations, and the system prompt (pi
    # regenerates the system prompt from config rather than storing it, so it is
    # configuration here too). Tools are rebound by name: every tool the dumped
    # agent had must be present in `tools`, or load raises. The model defaults to
    # the one recorded in the session; pass model: to override it.
    def self.load(path, provider:, tools: [], system_prompt: nil, model: nil,
                  max_turns: DEFAULT_MAX_TURNS)
      session = Session.load(path)
      toolbox = rebind_toolbox(session.tools, tools)
      context = session.context
      agent = new(provider: provider, system_prompt: system_prompt, tools: toolbox,
                  model: model || context.model&.model_id, max_turns: max_turns)
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

    def initialize(provider:, system_prompt: nil, tools: [], model: nil,
                   max_turns: DEFAULT_MAX_TURNS)
      @provider = provider
      @system_prompt = system_prompt
      @model = model
      @max_turns = max_turns
      @toolbox = tools.is_a?(Toolbox) ? tools : Toolbox.new(tools)
      @listeners = Hash.new { |h, k| h[k] = [] }

      @messages = []
      @messages << Message.system(system_prompt) if system_prompt
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
      emit(:agent_start, input: user_input)
      @messages << Message.user(user_input)

      final_text = nil
      final_response = nil
      aborted = false
      turns = 0

      loop do
        if signal&.aborted?
          aborted = true
          break
        end

        turns += 1
        raise Error, "exceeded max_turns (#{max_turns}) without a final answer" if turns > max_turns

        emit(:turn_start, turn: turns)
        response = @provider.chat(messages: @messages, tools: @toolbox.to_schema, model: @model)
        final_response = response
        @messages << response.message
        @usage += response.usage
        emit(:message, message: response.message, usage: response.usage)

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

    # The turns to persist: the history without the system prompt, which is
    # configuration re-supplied on resume rather than part of the conversation.
    def conversation
      @messages.reject { |message| message.role == :system }
    end

    def run_tool_calls(tool_calls)
      tool_calls.map do |call|
        emit(:tool_call, call: call)
        result = execute(call)
        message = Message.tool(content: result, tool_call_id: call.id, name: call.name)
        @messages << message
        emit(:tool_result, call: call, result: result, message: message)
        result
      end
    end

    def execute(call)
      tool = @toolbox[call.name]
      return "Error: unknown tool '#{call.name}'" if tool.nil?

      tool.call(call.arguments)
    rescue StandardError => e
      # A tool raising should not kill the loop; report it back to the model so
      # it can recover or apologize. This mirrors how pi treats tool failures.
      "Error running tool '#{call.name}': #{e.class}: #{e.message}"
    end

    def emit(event, **payload)
      @listeners[event].each { |l| l.call(payload) }
      @listeners[:_all].each { |l| l.call(event, payload) }
    end
  end
end
