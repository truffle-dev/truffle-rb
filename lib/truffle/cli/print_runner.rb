# frozen_string_literal: true

module Truffle
  module CLI
    module_function

    # Drive a single-shot text or JSON run. Terminal text streams only the final
    # prompt so the historical contract remains "last assistant turn wins";
    # earlier prompts are buffered context-building turns.
    def run_print(args, out: $stdout, err: $stderr, input: $stdin, agent_builder: nil)
      renderer = nil
      agent = (agent_builder || method(:build_cli_agent)).call(args)
      assembled = print_input(args, input)
      return run_print_json(agent, assembled, out) if args.mode == "json"

      final = nil
      agent.on(:agent_end) { |payload| final = final_print_response(payload) }
      renderer = terminal_print_renderer(args, agent, assembled, out, err)
      run_print_prompts(agent, assembled, renderer)
      renderer ? renderer.finish(final) : render_print_text(final, out: out, err: err)
    rescue Truffle::Error => e
      renderer&.finish(nil)
      err.puts e.message
      1
    end

    def run_print_json(agent, assembled, out)
      agent.on { |event, payload| render_print_json(event, payload, out: out) }
      assembled.prompts.each_with_index do |prompt, index|
        images = index.zero? ? assembled.images : []
        agent.run(prompt, images: images)
      end
      0
    end

    def terminal_print_renderer(args, agent, assembled, out, err)
      return nil if assembled.prompts.empty?
      return nil unless terminal_streaming?(agent, out, disabled: args.no_stream)

      TerminalRenderer.new(out: out, err: err)
    end

    def run_print_prompts(agent, assembled, renderer)
      last_index = assembled.prompts.length - 1
      assembled.prompts.each_with_index do |prompt, index|
        images = index.zero? ? assembled.images : []
        if renderer && index == last_index
          run_streamed_print_turn(agent, prompt, images, renderer)
        else
          agent.run(prompt, images: images)
        end
      end
    end

    def run_streamed_print_turn(agent, prompt, images, renderer)
      renderer.attach(agent)
      renderer.start_turn
      signal = AbortSignal.new
      with_interrupt_abort(signal) do
        agent.run_stream(prompt, images: images, signal: signal) do |event|
          renderer.stream(event)
        end
      end
    end

    private_class_method :run_print, :run_print_json, :terminal_print_renderer,
                         :run_print_prompts, :run_streamed_print_turn
  end
end
