# frozen_string_literal: true

module Truffle
  # Prompt-template helpers for slash-command style prompts, ported from pi's
  # prompt-templates.ts. Loading templates from disk and command execution live in
  # later command slices; this module is the pure argument layer they share.
  module PromptTemplates
    module_function

    PLACEHOLDER_PATTERN =
      /\$\{(\d+):-([^}]*)\}|\$\{@:(\d+)(?::(\d+))?\}|\$(ARGUMENTS|@|\d+)/

    # Parse command arguments with the same small bash-style quote handling pi
    # uses: whitespace separates args, single and double quotes group text, and
    # quote characters are removed. Backslash escaping is intentionally not part
    # of pi's parser.
    def parse_command_args(args_string)
      args = []
      current = +""
      in_quote = nil

      args_string.each_char do |char|
        if in_quote
          if char == in_quote
            in_quote = nil
          else
            current << char
          end
        elsif ['"', "'"].include?(char)
          in_quote = char
        elsif char.match?(/\s/)
          unless current.empty?
            args << current
            current = +""
          end
        else
          current << char
        end
      end

      args << current unless current.empty?
      args
    end

    # Substitute pi's prompt-template placeholders:
    # $1, $2, ...             positional arguments
    # $@ and $ARGUMENTS       all arguments joined with spaces
    # ${N:-default}           positional argument with fallback
    # ${@:N} / ${@:N:L}       bash-style argument slices
    #
    # Replacement is single-pass over the template only; argument/default text is
    # not recursively substituted.
    def substitute_args(content, args)
      all_args = args.join(" ")

      content.gsub(PLACEHOLDER_PATTERN) do
        match = Regexp.last_match
        if match[1]
          value = args[match[1].to_i - 1]
          value.nil? || value.empty? ? match[2] : value
        elsif match[3]
          slice_args(args, match[3].to_i, match[4]&.to_i)
        elsif %w[ARGUMENTS @].include?(match[5])
          all_args
        else
          args[match[5].to_i - 1] || ""
        end
      end
    end

    def slice_args(args, start_arg, length)
      start_index = [start_arg - 1, 0].max
      selected = length ? args.slice(start_index, length) : args.slice(start_index..)
      Array(selected).join(" ")
    end
    private_class_method :slice_args
  end
end
