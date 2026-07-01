# frozen_string_literal: true

module Truffle
  module CLI
    REPL_PROMPT = "truffle> "
    REPL_EXIT_COMMANDS = %w[/exit /quit exit quit].freeze

    module_function

    # Initial line-oriented interactive mode. Pi's interactive mode is a full TUI;
    # this ports the durable behavior first: reuse one agent, process CLI-provided
    # prompts before the loop, then read user turns until EOF or an exit command.
    # Streams and the agent builder are injectable so the loop can be tested
    # without a terminal or provider.
    def run_repl(args, out: $stdout, err: $stderr, input: $stdin, agent_builder: nil)
      agent = (agent_builder || method(:build_cli_agent)).call(args)
      current_response = nil
      agent.on(:agent_end) { |payload| current_response = final_print_response(payload) }
      reset_response = -> { current_response = nil }
      read_response = -> { current_response }
      renderer =
        if terminal_streaming?(agent, out, disabled: args.no_stream)
          TerminalRenderer.new(out: out, err: err).attach(agent)
        end

      out.puts "Truffle interactive. Type /exit to quit."
      initial_input = repl_input(args)
      initial_input.prompts.each_with_index do |prompt, index|
        images = index.zero? ? initial_input.images : []
        run_repl_turn(
          agent, prompt,
          images: images,
          out: out,
          err: err,
          response: reset_response,
          result: read_response,
          renderer: renderer
        )
      end

      loop do
        out.write REPL_PROMPT
        line = input.gets
        break if line.nil?

        prompt = line.chomp
        break if repl_exit_command?(prompt)
        next if prompt.strip.empty?

        run_repl_turn(
          agent, prompt,
          out: out,
          err: err,
          response: reset_response,
          result: read_response,
          renderer: renderer
        )
      end

      0
    rescue Interrupt
      out.puts
      0
    rescue Truffle::Error => e
      err.puts e.message
      1
    end

    def run_repl_turn(agent, prompt, images: [], out: $stdout, err: $stderr,
                      response: nil, result: nil, renderer: nil)
      response&.call
      if renderer
        return run_streaming_repl_turn(
          agent, prompt, images: images, renderer: renderer, result: result
        )
      end

      agent.run(prompt, images: images)
      render_print_text(result&.call, out: out, err: err)
    rescue Truffle::Error => e
      renderer&.finish(nil)
      err.puts e.message
      1
    end

    def run_streaming_repl_turn(agent, prompt, images:, renderer:, result:)
      renderer.start_turn
      signal = AbortSignal.new
      with_interrupt_abort(signal) do
        agent.run_stream(prompt, images: images, signal: signal) do |event|
          renderer.stream(event)
        end
      end

      renderer.finish(result&.call)
    end

    def repl_input(args)
      messages = args.messages.dup
      file_input = print_file_input(args.file_args)
      parts = []
      parts << file_input.text unless file_input.text.empty?
      parts << messages.shift unless messages.empty?
      initial = parts.empty? ? nil : parts.join
      PrintInput.new(prompts: [initial, *messages].compact, images: file_input.images)
    end

    def repl_exit_command?(line)
      REPL_EXIT_COMMANDS.include?(line.strip.downcase)
    end

    private_class_method :run_repl_turn, :run_streaming_repl_turn,
                         :repl_input, :repl_exit_command?
  end
end
