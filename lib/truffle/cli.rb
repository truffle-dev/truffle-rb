# frozen_string_literal: true

module Truffle
  # Command-line surface for the `truffle` binary. `parse_args` is the Ruby port
  # of pi's `cli/args.ts` `parseArgs`: a pure function from an argv array to an
  # `Args` struct of parsed flags plus diagnostics, with no side effects. The
  # printHelp text, the REPL loop, and acting on the parsed flags are later
  # slices of roadmap item 19; this is the parser only.
  module CLI
    # The thinking levels pi accepts for `--thinking`, lowest to highest. Stored
    # as strings to match how the rest of the port records a thinking level.
    VALID_THINKING_LEVELS = %w[off minimal low medium high xhigh].freeze

    # The parsed command line. Scalar flags are nil until seen; the accumulator
    # flags (append_system_prompt, extensions, skills, prompt_templates, themes)
    # stay nil until their first occurrence and then hold an array, matching pi.
    # messages, file_args, diagnostics, and unknown_flags are always populated.
    # A diagnostic is `{ type: :error | :warning, message: String }`.
    Args = Struct.new(
      :provider, :model, :api_key, :system_prompt, :append_system_prompt,
      :thinking, :continue, :resume, :help, :version, :mode, :name,
      :no_session, :session, :session_id, :fork, :session_dir, :models,
      :tools, :exclude_tools, :no_tools, :no_builtin_tools, :extensions,
      :no_extensions, :print, :export, :no_skills, :skills, :prompt_templates,
      :no_prompt_templates, :themes, :no_themes, :no_context_files, :list_models,
      :offline, :verbose, :project_trust_override, :messages, :file_args,
      :unknown_flags, :diagnostics,
      keyword_init: true
    )

    # Boolean flags and their aliases: each token sets its member to true.
    SWITCHES = {
      "--help" => :help, "-h" => :help, "--version" => :version, "-v" => :version,
      "--continue" => :continue, "-c" => :continue, "--resume" => :resume, "-r" => :resume,
      "--no-session" => :no_session, "--no-tools" => :no_tools, "-nt" => :no_tools,
      "--no-builtin-tools" => :no_builtin_tools, "-nbt" => :no_builtin_tools,
      "--no-extensions" => :no_extensions, "-ne" => :no_extensions,
      "--no-skills" => :no_skills, "-ns" => :no_skills,
      "--no-prompt-templates" => :no_prompt_templates, "-np" => :no_prompt_templates,
      "--no-themes" => :no_themes, "--no-context-files" => :no_context_files,
      "-nc" => :no_context_files, "--verbose" => :verbose, "--offline" => :offline
    }.freeze

    # Project-trust overrides: --approve enables, --no-approve disables.
    TRUST_FLAGS = {
      "--approve" => true, "-a" => true, "--no-approve" => false, "-na" => false
    }.freeze

    # Flags that consume the next argument verbatim into a scalar member.
    SCALAR_FLAGS = {
      "--provider" => :provider, "--model" => :model, "--api-key" => :api_key,
      "--system-prompt" => :system_prompt, "--session" => :session,
      "--session-id" => :session_id, "--fork" => :fork,
      "--session-dir" => :session_dir, "--export" => :export
    }.freeze

    # Flags whose value is a comma list of names (trimmed, empties dropped).
    LIST_FLAGS = {
      "--tools" => :tools, "-t" => :tools,
      "--exclude-tools" => :exclude_tools, "-xt" => :exclude_tools
    }.freeze

    # Flags that append the next argument to a growing array member.
    ACCUMULATOR_FLAGS = {
      "--append-system-prompt" => :append_system_prompt,
      "--extension" => :extensions, "-e" => :extensions, "--skill" => :skills,
      "--prompt-template" => :prompt_templates, "--theme" => :themes
    }.freeze

    module_function

    # True when level is one of the accepted thinking levels.
    def valid_thinking_level?(level)
      VALID_THINKING_LEVELS.include?(level)
    end

    # Parse argv into an Args. A value-taking flag at the end of argv with no
    # value falls through to the unknown-flag branch (becoming
    # `unknown_flags[name] = true`) rather than erroring, mirroring pi's
    # `arg === "--x" && i + 1 < length` guards.
    def parse_args(argv)
      result = Args.new(messages: [], file_args: [], unknown_flags: {}, diagnostics: [])
      index = 0
      index = advance(argv, index, result) while index < argv.length
      result
    end

    # Handle the token at index. Each apply_* returns the index of the last token
    # it consumed (so the caller steps one past it) or nil to defer to the next
    # handler. The fallback always consumes, so one of them always answers.
    def advance(argv, index, result)
      arg = argv[index]
      last = apply_switch(arg, index, result) ||
             apply_scalar(argv, index, arg, result) ||
             apply_list(argv, index, arg, result) ||
             apply_accumulator(argv, index, arg, result) ||
             apply_validated(argv, index, arg, result) ||
             apply_message_flags(argv, index, arg, result) ||
             apply_fallback(argv, index, arg, result)
      last + 1
    end

    def apply_switch(arg, index, result)
      if SWITCHES.key?(arg)
        result[SWITCHES[arg]] = true
        index
      elsif TRUST_FLAGS.key?(arg)
        result.project_trust_override = TRUST_FLAGS[arg]
        index
      end
    end

    def apply_scalar(argv, index, arg, result)
      key = SCALAR_FLAGS[arg]
      return nil unless key && index + 1 < argv.length

      result[key] = argv[index + 1]
      index + 1
    end

    def apply_list(argv, index, arg, result)
      key = LIST_FLAGS[arg]
      return nil unless key && index + 1 < argv.length

      result[key] = split_names(argv[index + 1])
      index + 1
    end

    def apply_accumulator(argv, index, arg, result)
      key = ACCUMULATOR_FLAGS[arg]
      return nil unless key && index + 1 < argv.length

      (result[key] ||= []) << argv[index + 1]
      index + 1
    end

    # Flags that validate or transform their value: --mode (accepted set only),
    # --thinking (warns on unknown), --models (comma list keeping blanks), and
    # --name (errors when its value is missing instead of falling through).
    def apply_validated(argv, index, arg, result)
      case arg
      when "--mode"
        return nil unless index + 1 < argv.length

        mode = argv[index + 1]
        result.mode = mode if %w[text json rpc].include?(mode)
        index + 1
      when "--thinking"
        return nil unless index + 1 < argv.length

        set_thinking(argv[index + 1], result)
        index + 1
      when "--models"
        return nil unless index + 1 < argv.length

        result.models = argv[index + 1].split(",").map(&:strip)
        index + 1
      when "--name", "-n"
        set_name(argv, index, result)
      end
    end

    # --print/-p sets the flag and optionally captures a following message;
    # --list-models takes an optional search pattern.
    def apply_message_flags(argv, index, arg, result)
      case arg
      when "--print", "-p"
        result.print = true
        capture_print_message(argv, index, result)
      when "--list-models"
        capture_list_models(argv, index, result)
      end
    end

    # @files become file args (prefix stripped); an unrecognized --flag is an
    # unknown flag; a lone -short is an error; anything else is a message.
    def apply_fallback(argv, index, arg, result)
      if arg.start_with?("@")
        result.file_args << arg[1..]
        index
      elsif arg.start_with?("--")
        parse_unknown_long_flag(arg, argv, index, result)
      elsif arg.start_with?("-")
        result.diagnostics << { type: :error, message: "Unknown option: #{arg}" }
        index
      else
        result.messages << arg
        index
      end
    end

    def set_thinking(level, result)
      if valid_thinking_level?(level)
        result.thinking = level
      else
        valid = VALID_THINKING_LEVELS.join(", ")
        result.diagnostics << {
          type: :warning,
          message: "Invalid thinking level \"#{level}\". Valid values: #{valid}"
        }
      end
    end

    def set_name(argv, index, result)
      if index + 1 < argv.length
        result.name = argv[index + 1]
        index + 1
      else
        result.diagnostics << { type: :error, message: "--name requires a value" }
        index
      end
    end

    # The next arg becomes a --print message unless it is a file arg or a flag,
    # though a "---"-prefixed token is treated as a message, matching pi.
    def capture_print_message(argv, index, result)
      nxt = argv[index + 1]
      if !nxt.nil? && !nxt.start_with?("@") && (!nxt.start_with?("-") || nxt.start_with?("---"))
        result.messages << nxt
        index + 1
      else
        index
      end
    end

    def capture_list_models(argv, index, result)
      nxt = argv[index + 1]
      if index + 1 < argv.length && !nxt.start_with?("-") && !nxt.start_with?("@")
        result.list_models = argv[index + 1]
        index + 1
      else
        result.list_models = true
        index
      end
    end

    # Split a comma list into trimmed, non-empty names.
    def split_names(value)
      value.split(",").map(&:strip).reject(&:empty?)
    end

    # Handle a `--something` flag the parser does not recognize. `--key=value`
    # records the pair; otherwise the next non-flag argument becomes the value
    # (consumed) and a missing or flag-shaped next argument records `true`.
    # Returns the index of the last token consumed. Ports pi's unknown-flag
    # branch so extensions can claim their own flags later.
    def parse_unknown_long_flag(arg, argv, index, result)
      eq = arg.index("=")
      if eq
        result.unknown_flags[arg[2...eq]] = arg[(eq + 1)..]
        return index
      end

      name = arg[2..]
      nxt = argv[index + 1]
      if !nxt.nil? && !nxt.start_with?("-") && !nxt.start_with?("@")
        result.unknown_flags[name] = nxt
        index + 1
      else
        result.unknown_flags[name] = true
        index
      end
    end

    private_class_method :advance, :apply_switch, :apply_scalar, :apply_list,
                         :apply_accumulator, :apply_validated, :apply_message_flags,
                         :apply_fallback, :set_thinking, :set_name,
                         :capture_print_message, :capture_list_models,
                         :split_names, :parse_unknown_long_flag
  end
end
