# frozen_string_literal: true

require_relative "../extensions"

module Truffle
  module Extensions
    # Resolves provider config values the way pi does for api keys and headers:
    # literal text, `$ENV` / `${ENV}` interpolation, `$$` for a literal dollar,
    # and `$!` for a literal bang. Command-backed `!value` resolution is deferred
    # until the port has a safe command execution policy for config.
    module ConfigValues
      module_function

      def resolve(value, provider_name:, label:)
        return nil if value.nil?

        string = value.to_s
        if string.start_with?("!")
          raise Error,
                "extension provider #{provider_name.inspect} uses command #{label} values; " \
                "command resolution is not supported yet"
        end

        resolved = interpolate(string)
        return resolved unless resolved.nil?

        raise Error,
              "extension provider #{provider_name.inspect} has unresolved #{label} " \
              "environment reference"
      end

      def interpolate(string)
        resolved = +""
        index = 0
        while index < string.length
          dollar = string.index("$", index)
          unless dollar
            resolved << string[index..]
            break
          end

          resolved << string[index...dollar]
          index = append_interpolation(string, dollar, resolved)
          return nil if index.nil?
        end
        resolved
      end

      def append_interpolation(string, dollar, resolved)
        char = string[dollar + 1]
        case char
        when "$", "!"
          resolved << char
          dollar + 2
        when "{"
          append_braced_env(string, dollar, resolved)
        else
          append_bare_env(string, dollar, resolved)
        end
      end

      def append_braced_env(string, dollar, resolved)
        close = string.index("}", dollar + 2)
        unless close
          resolved << "$"
          return dollar + 1
        end

        name = string[(dollar + 2)...close]
        unless env_name?(name)
          resolved << string[dollar..close]
          return close + 1
        end

        value = ENV.fetch(name, nil)
        return nil if value.nil?

        resolved << value
        close + 1
      end

      def append_bare_env(string, dollar, resolved)
        match = string[(dollar + 1)..]&.match(/\A[A-Za-z_][A-Za-z0-9_]*/)
        unless match
          resolved << "$"
          return dollar + 1
        end

        value = ENV.fetch(match[0], nil)
        return nil if value.nil?

        resolved << value
        dollar + 1 + match[0].length
      end

      def env_name?(name)
        /\A[A-Za-z_][A-Za-z0-9_]*\z/.match?(name)
      end
    end
  end
end
