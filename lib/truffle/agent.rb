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
        if turns > max_turns
          raise Error, "exceeded max_turns (#{max_turns}) without a final answer"
        end

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

    private

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
