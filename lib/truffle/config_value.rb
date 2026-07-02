# frozen_string_literal: true

require "open3"
require "timeout"

module Truffle
  # Resolve a configuration value that may be a literal, an environment-variable
  # template, or a shell command. This is the Ruby port of pi's
  # resolve-config-value.ts, used there for API keys and request headers so a
  # secret can live as `!op read op://vault/item/field` or `${OPENAI_API_KEY}`
  # instead of sitting in plaintext config.
  #
  # A value beginning with "!" is a shell command: it runs once through the
  # shell, its trimmed stdout is the value, and the result (including a failure
  # that yields nil) is cached for the process lifetime. Any other value is a
  # template: `$NAME` and `${NAME}` interpolate an environment variable, `$$`
  # escapes a literal "$", and `$!` escapes a literal "!". An unterminated `${`
  # or an invalid name like `${1bad}` is kept verbatim. Environment lookup falls
  # back from the caller-supplied `env` hash to the process environment, and an
  # empty string counts as absent (matching pi's `||` falsiness). A template with
  # any unresolved variable resolves to nil.
  #
  # Wiring this into provider and settings key/header resolution is a follow-up;
  # this module ports the resolver itself.
  module ConfigValue
    # pi caps a config-value command at 10 seconds.
    COMMAND_TIMEOUT_SECONDS = 10
    # An environment variable name: a letter or underscore, then word chars.
    ENV_VAR_NAME_RE = /\A[A-Za-z_][A-Za-z0-9_]*\z/
    # The same name anchored only at the start, for the bare `$NAME` form.
    ENV_VAR_NAME_PREFIX_RE = /\A[A-Za-z_][A-Za-z0-9_]*/

    # Raised by the *_or_raise resolvers when a value cannot be produced.
    class ResolutionError < StandardError; end

    # One piece of a parsed template: either a run of literal text (:literal) or
    # an environment-variable reference (:env). `value` holds the text or the
    # variable name.
    Part = Struct.new(:type, :value)

    # A parsed config value: a :command (with the raw `!...` string) or a
    # :template (with its ordered parts).
    Reference = Struct.new(:type, :config, :parts)

    # Command results persist for the process lifetime like pi's Map. The mutex
    # guards the cache because truffle-rb resolves work under a threaded runtime.
    @command_cache = {}
    @cache_mutex = Mutex.new

    module_function

    # Resolve a config value, caching shell-command results. Returns the resolved
    # string, or nil when a command fails or a template has an unresolved var.
    def resolve(config, env: nil)
      reference = parse_reference(config)
      return execute_command(reference.config) if reference.type == :command

      resolve_template(reference.parts, env)
    end

    # Resolve a config value without consulting or populating the command cache.
    def resolve_uncached(config, env: nil)
      reference = parse_reference(config)
      return execute_command_uncached(reference.config) if reference.type == :command

      resolve_template(reference.parts, env)
    end

    # Resolve a config value or raise ResolutionError with a message naming what
    # failed: the shell command, the single missing variable, the several missing
    # variables, or the description alone.
    def resolve_or_raise(config, description, env: nil)
      resolved = resolve_uncached(config, env: env)
      return resolved unless resolved.nil?

      reference = parse_reference(config)
      if reference.type == :command
        raise ResolutionError,
              "Failed to resolve #{description} from shell command: #{reference.config[1..]}"
      end

      missing = missing_env_var_names(config, env: env)
      raise ResolutionError, resolution_failure_message(description, missing)
    end

    # The single environment variable a config value is exactly, or nil when it
    # is a command, a literal, or a mix of parts.
    def env_var_name(config)
      reference = parse_reference(config)
      return nil unless reference.type == :template
      return nil unless reference.parts.length == 1

      part = reference.parts[0]
      part&.type == :env ? part.value : nil
    end

    # Every distinct environment variable a config value references, in first-seen
    # order. A command references none.
    def env_var_names(config)
      reference = parse_reference(config)
      return [] unless reference.type == :template

      template_env_var_names(reference.parts)
    end

    # The referenced environment variables that resolve to nothing under `env`
    # plus the process environment.
    def missing_env_var_names(config, env: nil)
      env_var_names(config).reject { |name| resolve_env(name, env) }
    end

    # Whether a config value is a shell command (begins with "!").
    def command?(config)
      parse_reference(config).type == :command
    end

    # Whether a config value has no unresolved environment variables. A command
    # is always considered configured.
    def configured?(config, env: nil)
      missing_env_var_names(config, env: env).empty?
    end

    # Resolve each header value, dropping any that resolves to nothing. Returns
    # nil when nothing resolves.
    def resolve_headers(headers, env: nil)
      return nil unless headers

      resolved = {}
      headers.each do |key, value|
        resolved_value = resolve(value, env: env)
        resolved[key] = resolved_value if resolved_value && !resolved_value.empty?
      end
      resolved.empty? ? nil : resolved
    end

    # Resolve each header value or raise, naming the offending header. Returns
    # nil for nil headers.
    def resolve_headers_or_raise(headers, description, env: nil)
      return nil unless headers

      resolved = {}
      headers.each do |key, value|
        resolved[key] = resolve_or_raise(value, %(#{description} header "#{key}"), env: env)
      end
      resolved.empty? ? nil : resolved
    end

    # Clear the cached shell-command results.
    def clear_cache
      @cache_mutex.synchronize { @command_cache.clear }
    end

    # --- parsing ---------------------------------------------------------------

    # Classify a raw config value: a leading "!" marks a command, everything else
    # is a template that still needs its parts parsed.
    def parse_reference(config)
      return Reference.new(:command, config, nil) if config.start_with?("!")

      Reference.new(:template, nil, parse_template(config))
    end

    # Walk the string, splitting it into literal runs and environment references.
    # A "$" introduces an escape (`$$`, `$!`), a braced `${NAME}`, or a bare
    # `$NAME`; anything the grammar rejects is folded back into literal text.
    def parse_template(config)
      parts = []
      index = 0

      while index < config.length
        dollar = config.index("$", index)
        if dollar.nil?
          append_literal(parts, config[index..])
          break
        end

        append_literal(parts, config[index...dollar])
        index = consume_dollar(config, dollar, parts)
      end

      parts
    end

    # Handle the "$" at `dollar` and return the index to continue parsing from.
    def consume_dollar(config, dollar, parts)
      next_char = config[dollar + 1]

      if ["$", "!"].include?(next_char)
        append_literal(parts, next_char)
        return dollar + 2
      end

      return consume_braced(config, dollar, parts) if next_char == "{"

      consume_bare(config, dollar, parts)
    end

    # Handle a `${...}` form. A valid name becomes an env part; an unterminated
    # brace or an invalid name stays literal.
    def consume_braced(config, dollar, parts)
      close = config.index("}", dollar + 2)
      if close.nil?
        append_literal(parts, "$")
        return dollar + 1
      end

      name = config[(dollar + 2)...close]
      if ENV_VAR_NAME_RE.match?(name)
        parts << Part.new(:env, name)
      else
        append_literal(parts, config[dollar..close])
      end
      close + 1
    end

    # Handle a bare `$NAME` form. A matching prefix becomes an env part; a lone
    # "$" with no valid name following stays literal.
    def consume_bare(config, dollar, parts)
      match = config[(dollar + 1)..].match(ENV_VAR_NAME_PREFIX_RE)
      if match
        parts << Part.new(:env, match[0])
        return dollar + 1 + match[0].length
      end

      append_literal(parts, "$")
      dollar + 1
    end

    # Append literal text, merging into the previous literal part so adjacent
    # runs stay a single part. Empty text is ignored.
    def append_literal(parts, value)
      return if value.nil? || value.empty?

      last = parts.last
      if last && last.type == :literal
        last.value += value
        return
      end
      parts << Part.new(:literal, value)
    end

    # --- resolution ------------------------------------------------------------

    # Concatenate a template's parts, returning nil the moment a referenced
    # variable is unresolved.
    def resolve_template(parts, env)
      resolved = +""
      parts.each do |part|
        if part.type == :literal
          resolved << part.value
          next
        end

        value = resolve_env(part.value, env)
        return nil if value.nil?

        resolved << value
      end
      resolved
    end

    # Look up an environment variable, preferring the caller's `env` hash over the
    # process environment and treating an empty string as absent.
    def resolve_env(name, env)
      from_env = env && env[name]
      return from_env if from_env && !from_env.empty?

      from_process = ENV.fetch(name, nil)
      return from_process if from_process && !from_process.empty?

      nil
    end

    # The distinct :env part names in order.
    def template_env_var_names(parts)
      names = []
      parts.each do |part|
        next unless part.type == :env
        next if names.include?(part.value)

        names << part.value
      end
      names
    end

    # Build the message for a failed template resolution from the missing names.
    def resolution_failure_message(description, missing)
      case missing.length
      when 1
        "Failed to resolve #{description} from environment variable: #{missing[0]}"
      when 0
        # Defensive: a template resolves to nil only when a referenced variable
        # is missing, so this branch mirrors pi's final fallback and is not
        # reachable through the template path.
        "Failed to resolve #{description}"
      else
        "Failed to resolve #{description} from environment variables: #{missing.join(", ")}"
      end
    end

    # --- shell command execution ----------------------------------------------

    # Run a cached command, honoring a cached nil so a failing command is not
    # retried within the process lifetime.
    def execute_command(command_config)
      @cache_mutex.synchronize do
        return @command_cache[command_config] if @command_cache.key?(command_config)

        result = execute_command_uncached(command_config)
        @command_cache[command_config] = result
        result
      end
    end

    # Drop the leading "!" and run the rest through the shell.
    def execute_command_uncached(command_config)
      execute_shell(command_config[1..])
    end

    # Run a command through /bin/sh with a timeout, returning its trimmed stdout,
    # or nil on a non-zero exit, empty output, timeout, or a missing shell.
    def execute_shell(command)
      Open3.popen3("/bin/sh", "-c", command) do |stdin, stdout, stderr, wait_thr|
        stdin.close
        stderr_drain = Thread.new { stderr.read }
        output = read_with_timeout(stdout, wait_thr)
        stderr_drain.join
        next nil if output.nil?
        next nil unless wait_thr.value.success?

        trimmed = output.strip
        trimmed.empty? ? nil : trimmed
      end
    rescue SystemCallError
      nil
    end

    # Read stdout under the command timeout, killing the child and returning nil
    # if the deadline passes.
    def read_with_timeout(stdout, wait_thr)
      Timeout.timeout(COMMAND_TIMEOUT_SECONDS) { stdout.read }
    rescue Timeout::Error
      terminate(wait_thr)
      nil
    end

    # Kill a running child, ignoring the race where it has already exited.
    def terminate(wait_thr)
      Process.kill("KILL", wait_thr.pid)
    rescue SystemCallError
      nil
    end
  end
end
