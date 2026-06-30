# frozen_string_literal: true

module Truffle
  module CLI
    # The `--help` and `--version` output for the `truffle` binary, the Ruby port
    # of pi's `cli/args.ts` `printHelp`. Both are pure string builders so the
    # binary stays a thin caller and the text is testable offline. The options
    # block lists exactly the flags `parse_args` recognizes; the environment
    # variables and built-in tool names describe this harness's real surface
    # (three providers, six built-in tools), not pi's full provider matrix.
    APP_NAME = "truffle"

    module_function

    # The version line printed for `--version`.
    def version_text
      "#{APP_NAME} #{Truffle::VERSION}"
    end

    # The full help screen printed for `--help`. Section headers are bold on a
    # terminal; pass color: false (the default) for plain text in tests and pipes.
    def help_text(color: false)
      bold = ->(text) { color ? "\e[1m#{text}\e[0m" : text }
      sections = [
        "#{bold.call(APP_NAME)} - AI coding assistant with read, bash, edit, write tools",
        usage_section(bold),
        options_section(bold),
        examples_section(bold),
        environment_section(bold),
        tools_section(bold)
      ]
      "#{sections.join("\n\n")}\n"
    end

    def usage_section(bold)
      <<~SECTION.chomp
        #{bold.call("Usage:")}
          #{APP_NAME} [options] [@files...] [messages...]
      SECTION
    end

    def options_section(bold)
      "#{bold.call("Options:")}\n#{indent(OPTIONS)}"
    end

    def examples_section(bold)
      "#{bold.call("Examples:")}\n#{indent(EXAMPLES)}"
    end

    # Indent each non-blank line by two spaces to sit under its section header.
    # The OPTIONS and EXAMPLES heredocs are kept flush-left for readability in
    # source; this restores the rendered indentation.
    def indent(text)
      text.lines.map { |line| line.strip.empty? ? line : "  #{line}" }.join
    end

    ENV_VARS = [
      ["ANTHROPIC_API_KEY", "Anthropic Claude API key"],
      ["OPENAI_API_KEY", "OpenAI GPT API key"],
      ["GEMINI_API_KEY", "Google Gemini API key"],
      [Config::ENV_AGENT_DIR,
       "Config directory (default: ~/#{Config::CONFIG_DIR_NAME}/agent)"]
    ].freeze

    def environment_section(bold)
      width = ENV_VARS.map { |name, _| name.length }.max
      rows = ENV_VARS.map { |name, desc| "  #{name.ljust(width)}  #{desc}" }
      "#{bold.call("Environment Variables:")}\n#{rows.join("\n")}"
    end

    def tools_section(bold)
      <<~SECTION.chomp
        #{bold.call("Built-in Tool Names:")}
          read   Read file contents
          bash   Execute bash commands
          edit   Edit files with find/replace
          write  Write files (creates/overwrites)
          grep   Search file contents (read-only, off by default)
          find   Find files by glob pattern (read-only, off by default)
      SECTION
    end

    OPTIONS = <<~OPTS.chomp
      --provider <name>              Provider name
      --model <pattern>              Model pattern or ID (supports "provider/id" and ":<thinking>")
      --api-key <key>                API key (defaults to env vars)
      --system-prompt <text>         System prompt (default: coding assistant prompt)
      --append-system-prompt <text>  Append text to the system prompt (repeatable)
      --mode <mode>                  Output mode: text (default), json, or rpc
      --print, -p                    Non-interactive mode: process prompt and exit
      --continue, -c                 Continue previous session
      --resume, -r                   Select a session to resume
      --session <path|id>            Use specific session file or partial UUID
      --session-id <id>              Use exact project session ID, creating it if missing
      --fork <path|id>               Fork specific session file or partial UUID into a new session
      --session-dir <dir>            Directory for session storage and lookup
      --no-session                   Don't save session (ephemeral)
      --name, -n <name>              Set session display name
      --models <patterns>            Comma-separated model patterns for cycling
      --no-tools, -nt                Disable all tools by default
      --no-builtin-tools, -nbt       Disable built-in tools but keep extension/custom tools
      --tools, -t <tools>            Comma-separated allowlist of tool names to enable
      --exclude-tools, -xt <tools>   Comma-separated denylist of tool names to disable
      --thinking <level>             Thinking level: off, minimal, low, medium, high, xhigh
      --extension, -e <path>         Load an extension file (repeatable)
      --no-extensions, -ne           Disable extension discovery (explicit -e paths still work)
      --skill <path>                 Load a skill file or directory (repeatable)
      --no-skills, -ns               Disable skills discovery and loading
      --prompt-template <path>       Load a prompt template file or directory (repeatable)
      --no-prompt-templates, -np     Disable prompt template discovery and loading
      --theme <path>                 Load a theme file or directory (repeatable)
      --no-themes                    Disable theme discovery and loading
      --no-context-files, -nc        Disable AGENTS.md and CLAUDE.md discovery and loading
      --export <file>                Export session file to HTML and exit
      --list-models [search]         List available models (with optional fuzzy search)
      --verbose                      Force verbose startup
      --approve, -a                  Trust project-local files for this run
      --no-approve, -na              Ignore project-local files for this run
      --offline                      Disable startup network operations
      --help, -h                     Show this help
      --version, -v                  Show version number
    OPTS

    EXAMPLES = <<~EX.chomp
      # Interactive mode with an initial prompt
      #{APP_NAME} "List all .rb files in lib/"

      # Include files in the initial message
      #{APP_NAME} @prompt.md "What does this describe?"

      # Non-interactive mode (process and exit)
      #{APP_NAME} -p "List all .rb files in lib/"

      # Continue the previous session
      #{APP_NAME} --continue "What did we discuss?"

      # Use a different model
      #{APP_NAME} --provider openai --model gpt-4o-mini "Refactor this code"

      # Use a model with a thinking level shorthand
      #{APP_NAME} --model sonnet:high "Solve this complex problem"

      # Read-only review (no file modifications possible)
      #{APP_NAME} --tools read,grep,find -p "Review the code in lib/"
    EX

    private_class_method :usage_section, :options_section, :examples_section,
                         :environment_section, :tools_section, :indent
  end
end
