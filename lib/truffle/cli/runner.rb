# frozen_string_literal: true

module Truffle
  module CLI
    # The thin entry point behind the `truffle` executable. It parses argv,
    # surfaces the parser's diagnostics, and acts on the terminal flags the
    # harness supports today: `--version`, `--help`, `--list-models`, the
    # single-shot print run (`--print` or `--mode json`), and the initial
    # line-oriented interactive REPL. This is the Ruby counterpart of the top of
    # pi's `main.ts` dispatcher, narrowed to the slices that exist. RPC and
    # `--export` are later slices of roadmap item 19.
    #
    # `run` takes injectable out/err/input streams and RETURNS an exit status
    # rather than calling `exit`, so the whole dispatch is testable offline with
    # StringIO and the executable stays a one-line caller. `agent_builder:` is an
    # injection seam: tests hand in a stub agent, production falls back to a real
    # provider-backed agent builder.

    # Exit status when the only instruction is a flag the binary cannot act on yet.
    EXIT_NOT_IMPLEMENTED = 2

    # The builtin tools a print run wires by default, in pi's coding-agent order.
    # Each factory binds to the working directory; `print_tools` filters this set
    # by the parsed tool flags.
    BUILTIN_TOOL_FACTORIES = {
      "read" => Tools.method(:read), "write" => Tools.method(:write),
      "bash" => Tools.method(:bash), "edit" => Tools.method(:edit),
      "find" => Tools.method(:find), "grep" => Tools.method(:grep)
    }.freeze
    FileInput = Struct.new(:text, :images, keyword_init: true)
    PrintInput = Struct.new(:prompts, :images, keyword_init: true)

    module_function

    def run(argv, out: $stdout, err: $stderr, input: $stdin, agent_builder: nil)
      args = parse_args(argv)
      validate_session_id_args(args)
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

      return run_init(out: out, err: err) if args.init

      if args.mode == "rpc"
        err.puts "#{APP_NAME}: rpc mode is not implemented yet"
        return EXIT_NOT_IMPLEMENTED
      end

      if print_mode?(args)
        return run_print(args, out: out, err: err, input: input, agent_builder: agent_builder)
      end

      run_repl(args, out: out, err: err, input: input, agent_builder: agent_builder)
    end

    def run_init(out: $stdout, err: $stderr)
      result = Init.project
      out.puts "Initialized Truffle project."
      print_init_paths("created", result.created, out)
      print_init_paths("existing", result.existing, out)
      print_init_paths("migrated", result.migrated, out)
      result.warnings.each { |warning| err.puts "Warning: #{warning}" }
      0
    end

    def print_init_paths(label, paths, out)
      return if paths.empty?

      paths.each { |path| out.puts "#{label}: #{path}" }
    end

    # Drive a single-shot `--print` run: build the agent, prompt it with the
    # assembled messages in order, and render either the final assistant turn
    # (`--mode text`) or each agent event as newline-delimited JSON (`--mode json`).
    # Faithful to the text/JSON branches of pi's `runPrintMode`, narrowed to the
    # sessionless CLI slice this harness has today. An unresolvable provider/model
    # (or any harness error) surfaces on stderr with exit 1, the analog of pi's
    # `catch`. `agent_builder` lets a test inject a stub agent; production builds
    # one with `build_cli_agent`.
    def run_print(args, out: $stdout, err: $stderr, input: $stdin, agent_builder: nil)
      agent = (agent_builder || method(:build_cli_agent)).call(args)
      final = nil
      if args.mode == "json"
        agent.on { |event, payload| render_print_json(event, payload, out: out) }
      else
        agent.on(:agent_end) { |payload| final = final_print_response(payload) }
      end
      print_input = print_input(args, input)
      print_input.prompts.each_with_index do |prompt, index|
        agent.run(prompt, images: index.zero? ? print_input.images : [])
      end
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
    def print_input(args, input)
      messages = args.messages.dup
      parts = []
      stdin = piped_stdin(input)
      parts << stdin unless stdin.nil?
      file_input = print_file_input(args.file_args)
      parts << file_input.text unless file_input.text.empty?
      parts << messages.shift unless messages.empty?
      initial = parts.empty? ? nil : parts.join
      PrintInput.new(prompts: [initial, *messages].compact, images: file_input.images)
    end

    # Pi's @file processing for the print-mode slice. Text files are spliced
    # into the initial prompt as `<file name="absolute/path">` blocks. Supported
    # images attach as typed image blocks and leave an empty file marker in the
    # text prompt so the model still sees the filename. No resizing is done here;
    # this stays dependency-free and lets providers enforce their own limits.
    def print_file_input(file_args, cwd: Dir.pwd)
      Array(file_args).each_with_object(FileInput.new(text: +"", images: [])) do |file_arg, input|
        path = Tools::Path.resolve(file_arg, cwd)
        raise Truffle::Error, "Error: File not found: #{path}" unless File.exist?(path)

        next if File.empty?(path)

        image = Content::Image.from_file(path)
        if image
          input.text << "<file name=\"#{path}\"></file>\n"
          input.images << image
          next
        end

        content = File.binread(path).force_encoding(Encoding::UTF_8).scrub
        input.text << "<file name=\"#{path}\">\n#{content}\n</file>\n"
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

    # Build the provider-backed agent a CLI mode drives. The provider is taken
    # from `--provider` or inferred from `--model`; an api key flag passes
    # through. Tools are the builtin set filtered by the parsed flags. Raises
    # Truffle::Error when neither a provider nor a model-named provider resolves,
    # which `run_print` turns into a stderr message and exit 1.
    def build_cli_agent(args, cwd: Dir.pwd)
      return load_cli_agent(args, cwd: cwd) if args.continue || args.session

      if args.session_id && !args.no_session && !print_mode?(args)
        existing = exact_session_id_path(args.session_id, args, cwd: cwd)
        return load_cli_agent(args, cwd: cwd, path: existing) if existing
      end

      tools = print_tools(args, cwd)
      session = new_cli_session(args, cwd: cwd, tools: tools)
      system_prompt = cli_system_prompt(args, cwd: cwd, tools: tools)
      options = { provider: args.provider&.to_sym, model: args.model, cwd: cwd,
                  system_prompt: system_prompt, tools: tools, session: session }
      options[:api_key] = args.api_key if args.api_key
      agent = Truffle.agent(**options)
      record_cli_model_change(agent, session)
      agent
    end

    def new_cli_session(args, cwd: Dir.pwd, tools: [])
      return nil if args.no_session || print_mode?(args)

      Truffle::Session.create(cwd: cwd, dir: cli_session_dir(args, cwd),
                              id: args.session_id, tools: tools.map(&:name))
    end

    def record_cli_model_change(agent, session)
      return unless session

      model = agent.model || (agent.provider.model if agent.provider.respond_to?(:model))
      return if model.nil? || model.empty?

      session.append_model_change(provider: agent.provider.name, model_id: model)
    end

    def load_cli_agent(args, cwd: Dir.pwd, path: nil)
      raise Truffle::Error, "cannot use --continue with --no-session" if args.no_session

      path = validate_session_path(path || continued_session_path(args, cwd: cwd), cwd: cwd)
      provider = cli_provider(args)
      tools = print_tools(args, cwd)
      Truffle::Agent.load(
        path,
        provider: provider,
        model: args.model,
        system_prompt: cli_system_prompt(args, cwd: cwd, tools: tools),
        tools: tools,
        extension_provider_overrides: cli_provider_options(args)
      )
    end

    def cli_system_prompt(args, cwd:, tools:)
      Truffle::SystemPrompt.build(
        cwd: cwd,
        custom_prompt: args.system_prompt,
        append_system_prompt: cli_append_system_prompt(args),
        selected_tools: tools.map(&:name),
        tool_snippets: cli_tool_snippets(tools),
        context_files: cli_context_files(args, cwd)
      )
    end

    def cli_append_system_prompt(args)
      parts = Array(args.append_system_prompt).reject { |part| part.to_s.strip.empty? }
      return nil if parts.empty?

      parts.join("\n\n")
    end

    def cli_tool_snippets(tools)
      tools.to_h { |tool| [tool.name, tool.description] }
    end

    def cli_context_files(args, cwd)
      return [] if args.no_context_files

      Truffle::ContextFiles.load(cwd: cwd, agent_dir: Truffle::Config.agent_dir)
    end

    def cli_provider(args)
      return nil unless args.provider

      Truffle.provider(args.provider.to_sym, **cli_provider_options(args))
    end

    def cli_provider_options(args)
      args.api_key ? { api_key: args.api_key } : {}
    end

    def continued_session_path(args, cwd: Dir.pwd)
      path =
        if args.session
          resolve_session_reference(args.session, args, cwd: cwd)
        else
          Truffle::Session.most_recent(cwd: cwd, dir: cli_session_dir(args, cwd))
        end
      raise Truffle::Error, "no session found for #{cwd}" unless path

      validate_session_path(path, cwd: cwd)
    end

    def validate_session_path(path, cwd: Dir.pwd)
      header = Truffle::Session.read_header(path)
      raise Truffle::Error, "not a valid Truffle session: #{path}" unless header

      Truffle::SessionCwd.assert_exists(session_cwd: header[:cwd], fallback_cwd: cwd,
                                        session_file: path)
      path
    end

    def exact_session_id_path(session_id, args, cwd: Dir.pwd)
      Truffle::SessionId.assert_valid!(session_id)
      Truffle::Session.list(cwd: cwd, dir: cli_session_dir(args, cwd)).find do |summary|
        summary.id == session_id
      end&.path
    end

    def resolve_session_reference(reference, args, cwd: Dir.pwd)
      path = File.expand_path(reference, cwd)
      return path if File.file?(path)

      matches = Truffle::Session.list(cwd: cwd, dir: cli_session_dir(args, cwd)).select do |summary|
        summary.id.start_with?(reference) || File.basename(summary.path).include?(reference)
      end
      return matches.first.path if matches.length == 1
      return nil if matches.empty?

      raise Truffle::Error, "session reference is ambiguous: #{reference}"
    end

    def cli_session_dir(args, cwd)
      if args.session_dir
        File.expand_path(args.session_dir, cwd)
      else
        Truffle::Config.default_session_dir(cwd: cwd)
      end
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

    def validate_session_id_args(args)
      return unless args.session_id

      conflicts = []
      conflicts << "--session" if args.session
      conflicts << "--continue" if args.continue
      conflicts << "--resume" if args.resume
      if conflicts.any?
        args.diagnostics << {
          type: :error,
          message: "--session-id cannot be combined with #{conflicts.join(", ")}"
        }
        return
      end

      Truffle::SessionId.assert_valid!(args.session_id)
    rescue ArgumentError => e
      args.diagnostics << { type: :error, message: e.message }
    end

    private_class_method :run_init, :print_init_paths,
                         :run_print, :final_print_response, :print_input,
                         :print_file_input, :piped_stdin, :build_cli_agent, :print_tools,
                         :new_cli_session, :record_cli_model_change,
                         :load_cli_agent, :cli_system_prompt, :cli_append_system_prompt,
                         :cli_tool_snippets, :cli_context_files,
                         :cli_provider, :cli_provider_options,
                         :continued_session_path, :validate_session_path,
                         :exact_session_id_path, :resolve_session_reference,
                         :cli_session_dir,
                         :report_diagnostics, :color?, :print_mode?,
                         :validate_session_id_args
  end
end
