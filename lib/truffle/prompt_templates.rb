# frozen_string_literal: true

require_relative "frontmatter"

module Truffle
  # Prompt-template helpers for slash-command style prompts, ported from pi's
  # prompt-templates.ts. They load markdown prompt files from explicit
  # files/directories, parse the small argument language pi supports, and expand
  # `/name args` text into prompt content. Default prompt directories and command
  # actions live in later command slices.
  module PromptTemplates
    FALLBACK_DESCRIPTION_LENGTH = 60

    # A markdown prompt template loaded from disk. The file basename is the
    # command name, `description` comes from frontmatter or the first body line,
    # and `argument_hint` maps pi's `argument-hint` frontmatter key.
    Template = Struct.new(:name, :description, :argument_hint, :content, :file_path,
                          keyword_init: true)

    module_function

    PLACEHOLDER_PATTERN =
      /\$\{(\d+):-([^}]*)\}|\$\{@:(\d+)(?::(\d+))?\}|\$(ARGUMENTS|@|\d+)/

    # Load one markdown prompt file. Read or frontmatter parse failures return
    # nil, matching pi's best-effort prompt loading behavior.
    def load_file(file_path)
      expanded_path = File.expand_path(file_path)
      raw = File.read(expanded_path)
      frontmatter, body = Frontmatter.parse(raw)

      Template.new(
        name: File.basename(expanded_path, ".md"),
        description: description_for(frontmatter, body),
        argument_hint: string_or_nil(frontmatter["argument-hint"]),
        content: body,
        file_path: expanded_path
      )
    rescue StandardError
      nil
    end

    # Scan a directory's direct .md children in sorted order. The scan is
    # non-recursive and follows symlinks to files; broken symlinks and read
    # failures are skipped.
    def load_dir(dir)
      return [] unless File.directory?(dir)

      Dir.children(dir).sort.filter_map do |name|
        full_path = File.join(dir, name)
        next unless name.end_with?(".md") && File.file?(full_path)

        load_file(full_path)
      end
    rescue StandardError
      []
    end

    # Load prompt templates from explicit markdown files or directories. Relative
    # paths resolve from cwd; missing paths and non-markdown files are ignored.
    def load_paths(paths, cwd: Dir.pwd)
      paths.flat_map do |path|
        resolved = resolve_prompt_path(path, cwd)
        next [] unless resolved

        if File.directory?(resolved)
          load_dir(resolved)
        elsif resolved.end_with?(".md") && File.file?(resolved)
          template = load_file(resolved)
          template ? [template] : []
        else
          []
        end
      rescue StandardError
        []
      end
    end

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

    # Expand `/name args` when a matching template exists. Plain text, malformed
    # command text, and unknown commands pass through unchanged.
    def expand(text, templates)
      return text unless text.start_with?("/")

      match = text.match(%r{\A/([^\s]+)(?:\s+([\s\S]*))?\z})
      return text unless match

      template = templates.find { |candidate| candidate.name == match[1] }
      return text unless template

      substitute_args(template.content, parse_command_args(match[2] || ""))
    end

    def description_for(frontmatter, body)
      description = string_or_nil(frontmatter["description"])
      return description if description

      first_line = body.lines.map(&:chomp).find { |line| !line.strip.empty? }
      return "" unless first_line

      fallback = first_line[0, FALLBACK_DESCRIPTION_LENGTH]
      first_line.length > FALLBACK_DESCRIPTION_LENGTH ? "#{fallback}..." : fallback
    end
    private_class_method :description_for

    def resolve_prompt_path(path, cwd)
      trimmed = path.to_s.strip
      return nil if trimmed.empty?

      resolved = File.expand_path(trimmed, cwd)
      File.exist?(resolved) ? resolved : nil
    end
    private_class_method :resolve_prompt_path

    def string_or_nil(value)
      return nil if value.nil? || value == false

      string = value.to_s
      string.empty? ? nil : string
    end
    private_class_method :string_or_nil

    def slice_args(args, start_arg, length)
      start_index = [start_arg - 1, 0].max
      selected = length ? args.slice(start_index, length) : args.slice(start_index..)
      Array(selected).join(" ")
    end
    private_class_method :slice_args
  end
end
