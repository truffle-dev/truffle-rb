# frozen_string_literal: true

module Truffle
  module CLI
    # The thin entry point behind the `truffle` executable. It parses argv,
    # surfaces the parser's diagnostics, and acts on the terminal flags the
    # harness supports today: `--version`, `--help`, `--list-models`, and the
    # single-shot print run (`--print` or `--mode json`). This is the Ruby
    # counterpart of the top of pi's `main.ts` dispatcher, narrowed to the slices
    # that exist. RPC, the interactive REPL, and `--export` are later slices of
    # roadmap item 19, so those invocations report that and exit.
    #
    # `run` takes injectable out/err/input streams and RETURNS an exit status
    # rather than calling `exit`, so the whole dispatch is testable offline with
    # StringIO and the executable stays a one-line caller. `agent_builder:` is an
    # injection seam: tests hand in a stub agent, production falls back to
    # `build_print_agent`, which assembles a real provider-backed agent.

    # Exit status when the only instruction is a flag the binary cannot act on
    # yet (the interactive REPL is a later slice).
    EXIT_NOT_IMPLEMENTED = 2

    # The builtin tools a print run wires by default, in pi's coding-agent order.
    # Each factory binds to the working directory; `print_tools` filters this set
    # by the parsed tool flags.
    BUILTIN_TOOL_FACTORIES = {
      "read" => Tools.method(:read), "write" => Tools.method(:write),
      "bash" => Tools.method(:bash), "edit" => Tools.method(:edit),
      "find" => Tools.method(:find), "grep" => Tools.method(:grep)
    }.freeze

    module_function

    def run(argv, out: $stdout, err: $stderr, input: $stdin, agent_builder: nil)
      args = parse_args(argv)
      report_diagnostics(args.diagnostics, err)
      return 1 if args.diagnostics.any? { |diagnostic| diagnostic[:type] == :error }

      if args.version
        out.puts version_text
        return 0
      end

      if args.help
        out.puts help_text(color: color?(out))
        return 0
      end

      if args.list_models
        search = args.list_models == true ? nil : args.list_models
        out.print models_text(search: search)
        return 0
      end

      if args.mode == "rpc"
        err.puts "#{APP_NAME}: rpc mode is not implemented yet"
        return EXIT_NOT_IMPLEMENTED
      end

      if print_mode?(args)
        return run_print(args, out: out, err: err, input: input, agent_builder: agent_builder)
      end

      err.puts "#{APP_NAME}: interactive mode is not implemented yet"
      EXIT_NOT_IMPLEMENTED
    end

    # Drive a single-shot `--print` run: build the agent, prompt it with the
    # assembled messages in order, and render either the final assistant turn
    # (`--mode text`) or each agent event as newline-delimited JSON (`--mode json`).
    # Faithful to the text/JSON branches of pi's `runPrintMode`, narrowed to the
    # sessionless CLI slice this harness has today. An unresolvable provider/model
    # (or any harness error) surfaces on stderr with exit 1, the analog of pi's
    # `catch`. `agent_builder` lets a test inject a stub agent; production builds
    # one with `build_print_agent`.
    def run_print(args, out: $stdout, err: $stderr, input: $stdin, agent_builder: nil)
      agent = (agent_builder || method(:build_print_agent)).call(args)
      final = nil
      if args.mode == "json"
        agent.on { |event, payload| render_print_json(event, payload, out: out) }
      else
        agent.on(:agent_end) { |payload| final = final_print_response(payload) }
      end
      print_prompts(args, input).each { |prompt| agent.run(prompt) }
      return 0 if args.mode == "json"

      render_print_text(final, out: out, err: err)
    rescue Truffle::Error => e
      err.puts e.message
      1
    end

    # The Response a print run renders: pi reads the last conversation message
    # and only renders it when it is the assistant's, so a run that ended on a
    # tool result or produced no assistant turn renders nothing. Rebuilt from the
    # `:agent_end` payload because the event carries messages, not the Response.
    def final_print_response(payload)
      last = payload[:messages].last
      return nil unless last&.role == :assistant

      Response.new(message: last, stop_reason: payload[:stop_reason],
                   error_message: payload[:error_message])
    end

    # The ordered prompts a print run sends. Piped stdin, @file text, and the
    # first CLI message join into one initial prompt (pi's `buildInitialMessage`);
    # the remaining CLI messages follow as their own prompts. A run with none of
    # those sends nothing.
    def print_prompts(args, input)
      messages = args.messages.dup
      parts = []
      stdin = piped_stdin(input)
      parts << stdin unless stdin.nil?
      file_text = print_file_text(args.file_args)
      parts << file_text unless file_text.empty?
      parts << messages.shift unless messages.empty?
      initial = parts.empty? ? nil : parts.join
      [initial, *messages].compact
    end

    # The text half of pi's @file processing. Each non-empty file becomes a
    # `<file name="absolute/path">` block appended to the initial prompt. Image
    # attachments are a later slice because the current Agent#run accepts only a
    # text prompt; fail clearly instead of feeding binary data as text.
    def print_file_text(file_args, cwd: Dir.pwd)
      Array(file_args).each_with_object(+"") do |file_arg, text|
        path = Tools::Path.resolve(file_arg, cwd)
        raise Truffle::Error, "Error: File not found: #{path}" unless File.exist?(path)

        next if File.empty?(path)

        if Mime.detect_supported_image_mime_type_from_file(path)
          raise Truffle::Error, "Error: @file image arguments are not implemented yet: #{path}"
        end

        content = File.binread(path).force_encoding(Encoding::UTF_8).scrub
        text << "<file name=\"#{path}\">\n#{content}\n</file>\n"
      rescue Truffle::Error
        raise
      rescue StandardError => e
        raise Truffle::Error, "Error: Could not read file #{path}: #{e.message}"
      end
    end

    # The piped stdin content, or nil when stdin is a terminal or empty. Mirrors
    # pi's `readPipedStdin`, which returns undefined for an interactive stdin so
    # a bare `truffle -p "ask"` does not block on the keyboard.
    def piped_stdin(input)
      return nil if input.respond_to?(:tty?) && input.tty?

      content = input.read
      content.nil? || content.empty? ? nil : content
    end

    # Build the provider-backed agent a print run drives. The provider is taken
    # from `--provider` or inferred from `--model`; an api key flag passes
    # through. Tools are the builtin set filtered by the parsed flags. Raises
    # Truffle::Error when neither a provider nor a model-named provider resolves,
    # which `run_print` turns into a stderr message and exit 1.
    def build_print_agent(args, cwd: Dir.pwd)
      options = { provider: args.provider&.to_sym, model: args.model,
                  tools: print_tools(args, cwd) }
      options[:api_key] = args.api_key if args.api_key
      Truffle.agent(**options)
    end

    # The builtin tools a print run exposes, filtered by the parsed flags. No
    # tools at all under `--no-tools`/`--no-builtin-tools`; otherwise an explicit
    # `--tools` whitelist or `--exclude-tools` blacklist narrows the set.
    def print_tools(args, cwd)
      return [] if args.no_tools || args.no_builtin_tools

      names = BUILTIN_TOOL_FACTORIES.keys
      names &= args.tools if args.tools
      names -= args.exclude_tools if args.exclude_tools
      names.map { |name| BUILTIN_TOOL_FACTORIES[name].call(cwd: cwd) }
    end

    # Print each diagnostic on its own line, mirroring pi's red Error / yellow
    # Warning prefixes without the color (the binary's own color is gated on a
    # tty below, and plain text keeps these lines greppable in logs and tests).
    def report_diagnostics(diagnostics, err)
      diagnostics.each do |diagnostic|
        label = diagnostic[:type] == :error ? "Error" : "Warning"
        err.puts "#{label}: #{diagnostic[:message]}"
      end
    end

    # Color the help only when the output is an interactive terminal, the way
    # pi's chalk auto-disables when stdout is not a tty.
    def color?(out)
      out.respond_to?(:tty?) && out.tty?
    end

    def print_mode?(args)
      args.print || args.mode == "json"
    end

    private_class_method :run_print, :final_print_response, :print_prompts,
                         :print_file_text, :piped_stdin, :build_print_agent, :print_tools,
                         :report_diagnostics, :color?, :print_mode?
  end
end
