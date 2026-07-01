# frozen_string_literal: true

module Truffle
  # Shared run-loop helpers for Agent. #run and #run_stream differ only in how
  # they ask the provider for an assistant turn; the rest of the loop stays here.
  class Agent
    RunState = Struct.new(:final_text, :final_response, :aborted, keyword_init: true)
    TurnOutcome = Struct.new(:response, :final_text, :done, :retry, :aborted,
                             keyword_init: true)

    private

    def run_loop(user_input, images:, signal:, streaming:, stream_block:)
      prepared = prepare_user_input(user_input, images)
      return run_slash_action(prepared.fetch(:command)) if prepared[:action]

      start_run(prepared.fetch(:input), images)
      state = process_turns(streaming, signal, stream_block)
      emit_agent_end(state.final_text, state.final_response, state.aborted)
      state.final_text
    end

    def prepare_user_input(user_input, images)
      command = Array(images).empty? ? resolve_slash_command(user_input) : nil
      return { command: command, action: true } if command&.type == :action

      { input: command&.type == :prompt ? command.content : user_input }
    end

    def start_run(user_input, images)
      emit(:agent_start, input: user_input)
      append(Message.user_with_images(user_input, images: images))
      @overflow_recovery_attempted = false
      @retry_attempt = 0
    end

    def process_turns(streaming, signal, stream_block)
      state = RunState.new(aborted: false)
      turns = 0

      loop do
        state.aborted = true if signal&.aborted?
        break if state.aborted

        prepare_provider_turn(signal)
        turns += 1
        return max_turns_state(state) if turns > max_turns

        outcome = run_turn(turns, streaming, signal, stream_block)
        state.final_response = outcome.response
        state.aborted = outcome.aborted
        next if outcome.retry

        state.final_text = outcome.final_text
        break if outcome.done || outcome.aborted
      end

      state
    end

    def run_turn(turn, streaming, signal, stream_block)
      emit(:turn_start, turn: turn)
      response = request_assistant_turn(streaming, signal, stream_block)
      record_assistant_response(response)
      if handle_recovery(response, signal) == :retry
        return TurnOutcome.new(response: response, retry: true)
      end

      if response.tool_calls?
        tool_results = run_tool_calls(response.tool_calls)
        emit(:turn_end, turn: turn, tool_results: tool_results)
        TurnOutcome.new(response: response, done: false)
      else
        emit(:turn_end, turn: turn, tool_results: [])
        TurnOutcome.new(response: response, final_text: response.text, done: true,
                        aborted: response.stop_reason == StopReason::ABORTED)
      end
    end

    def request_assistant_turn(streaming, signal, stream_block)
      streaming ? stream_current_turn(signal, &stream_block) : chat_current_turn
    end

    def record_assistant_response(response)
      append(response.message)
      @usage += response.usage
      @last_usage = response.usage
      emit(:message, message: response.message, usage: response.usage)
    end

    def max_turns_state(state)
      state.final_response = Response.new(message: Message.assistant(content: []),
                                          stop_reason: StopReason::ERROR,
                                          error_message: max_turns_error_message)
      state
    end
  end
end
