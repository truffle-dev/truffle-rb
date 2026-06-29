# frozen_string_literal: true

require_relative "../tool"
require_relative "path"
require_relative "truncate"
require_relative "find"

module Truffle
  module Tools
    # Engine for the `grep` tool. Nested so its private helpers (scan, render,
    # format_path) do not collide with the flat read/write helpers, matching the
    # pattern used by Bash, Edit, Find, and Gitignore.
    module Grep
      DEFAULT_LIMIT = 100
      BINARY_PROBE = "\x00".b.freeze

      # The shared search context, threaded through formatting so the helpers
      # stay under a sane argument count: the resolved root, whether it is a
      # directory (path output is relative vs basename), the context window, and
      # the per-file line cache populated during the scan.
      Ctx = Struct.new(:search_dir, :is_dir, :context_value, :cache, keyword_init: true)

      module_function

      # Search file contents for a pattern and format the matches the way pi's
      # grep does: "path:line: text" for a match line, "path-line- text" for a
      # context line, with the same bracketed truncation notices.
      def run(pattern:, cwd:, path: nil, glob: nil, ignore_case: false,
              literal: false, context: nil, limit: nil)
        search_dir = Path.resolve(path.nil? || path.empty? ? "." : path, cwd)
        raise "Path not found: #{search_dir}" unless File.exist?(search_dir)

        ctx = Ctx.new(search_dir: search_dir, is_dir: File.directory?(search_dir),
                      context_value: context_window(context), cache: {})
        regexp = build_regexp(pattern, ignore_case, literal)
        effective_limit = [1, limit.nil? ? DEFAULT_LIMIT : limit.to_i].max

        matches, limit_reached = scan(collect_files(ctx, glob), regexp, effective_limit, ctx.cache)
        return "No matches found" if matches.empty?

        render(matches, ctx, effective_limit, limit_reached)
      end

      # The context window is the number of lines to show on each side of a match.
      # A nil or non-positive value means no surrounding context.
      def context_window(context)
        value = context.to_i
        value.positive? ? value : 0
      end

      # pi hands the pattern to ripgrep (Rust regex). With no external binary the
      # natural engine is Ruby's own Regexp; `literal` escapes the pattern so it
      # matches verbatim, mirroring rg's --fixed-strings.
      def build_regexp(pattern, ignore_case, literal)
        source = literal ? Regexp.escape(pattern) : pattern
        Regexp.new(source, ignore_case ? Regexp::IGNORECASE : 0)
      rescue RegexpError => e
        raise "Invalid pattern: #{e.message}"
      end

      # Absolute paths to search. A single file is searched directly; a directory
      # is walked through Find so grep honors the same .git/node_modules floor and
      # .gitignore stack that find does, and a glob filters the same way.
      def collect_files(ctx, glob)
        return [ctx.search_dir] unless ctx.is_dir

        pattern = glob.nil? || glob.empty? ? "**/*" : glob
        Find.search(pattern, ctx.search_dir).filter_map do |rel|
          abs = File.join(ctx.search_dir, rel)
          abs if File.file?(abs)
        end
      end

      # Walk files in order, recording matches until the limit is hit. The file's
      # lines are cached so render can pull context lines without a second read.
      # rg stops at the limit and reports it reached; matching that, hitting the
      # limit returns limit_reached = true even when it was the last match.
      def scan(files, regexp, effective_limit, cache)
        matches = []
        files.each do |file|
          lines = cache[file] ||= read_lines(file)
          next unless lines.is_a?(Array)

          lines.each_with_index do |line, idx|
            next unless regexp.match?(line)

            matches << [file, idx + 1]
            return [matches, true] if matches.length >= effective_limit
          end
        end
        [matches, false]
      end

      # Read a file as lines, normalizing CRLF and lone CR to LF. A NUL byte marks
      # a binary file, which rg skips, so it is dropped from the search. An
      # unreadable file is dropped too. Invalid UTF-8 is scrubbed so a regex match
      # never raises on a stray byte.
      def read_lines(file)
        raw = read_binary(file)
        return raw if raw.is_a?(Symbol)
        return :binary if raw.include?(BINARY_PROBE)

        raw.force_encoding("UTF-8").scrub.gsub("\r\n", "\n").tr("\r", "\n").split("\n", -1)
      end

      def read_binary(file)
        File.binread(file)
      rescue SystemCallError
        :unreadable
      end

      # Format every match into output lines, byte-truncate the whole, then append
      # any of pi's three notices (match limit, byte limit, long lines truncated).
      def render(matches, ctx, effective_limit, limit_reached)
        lines_truncated = false
        output_lines = []
        matches.each do |file, line_number|
          block, truncated = format_block(file, line_number, ctx)
          lines_truncated ||= truncated
          output_lines.concat(block)
        end

        truncation = Truncate.head(output_lines.join("\n"), max_lines: Float::INFINITY)
        notices = notices_for(limit_reached, effective_limit, truncation.truncated, lines_truncated)
        output = truncation.content
        output += "\n\n[#{notices.join(". ")}]" unless notices.empty?
        output
      end

      # One match becomes one block: just the match line when context is zero, or
      # the surrounding window when context is set. Match lines use a ":" between
      # path and line number, context lines use "-", as pi (and grep -C) do.
      def format_block(file, line_number, ctx)
        rel = format_path(file, ctx)
        lines = ctx.cache[file]
        unless lines.is_a?(Array) && !lines.empty?
          return [["#{rel}:#{line_number}: (unable to read file)"], false]
        end

        window = ctx.context_value
        first = window.positive? ? [1, line_number - window].max : line_number
        last = window.positive? ? [lines.length, line_number + window].min : line_number
        build_block(rel, line_number, first, last, lines)
      end

      def build_block(rel, line_number, first, last, lines)
        truncated = false
        block = (first..last).map do |current|
          res = Truncate.truncate_line((lines[current - 1] || "").tr("\r", ""))
          truncated ||= res.truncated
          sep = current == line_number ? ":" : "-"
          "#{rel}#{sep}#{current}#{sep} #{res.text}"
        end
        [block, truncated]
      end

      # A match in a searched directory shows its path relative to that directory
      # (posix-separated); a single searched file shows its basename, as pi does.
      def format_path(file, ctx)
        return File.basename(file) unless ctx.is_dir

        file.delete_prefix("#{ctx.search_dir}/").tr("\\", "/")
      end

      def notices_for(limit_reached, effective_limit, byte_truncated, lines_truncated)
        notices = []
        if limit_reached
          notices << "#{effective_limit} matches limit reached. " \
                     "Use limit=#{effective_limit * 2} for more, or refine pattern"
        end
        if byte_truncated
          notices << "#{Truncate.format_size(Truncate::DEFAULT_MAX_BYTES)} limit reached"
        end
        if lines_truncated
          notices << "Some lines truncated to #{Truncate::GREP_MAX_LINE_LENGTH} chars. " \
                     "Use read tool to see full lines"
        end
        notices
      end
    end

    GREP_DESCRIPTION =
      "Search file contents for a pattern. Returns matching lines with file " \
      "paths and line numbers. Respects .gitignore. Output is truncated to " \
      "#{Grep::DEFAULT_LIMIT} matches or #{Truncate::DEFAULT_MAX_BYTES / 1024}KB " \
      "(whichever is hit first). Long lines are truncated to " \
      "#{Truncate::GREP_MAX_LINE_LENGTH} chars.".freeze

    # Build pi's `grep` tool, bound to a working directory. The model passes a
    # `pattern` (a regular expression, or a literal string when `literal` is set),
    # an optional `path` (file or directory, default the current directory), an
    # optional `glob` filter, and the `ignoreCase`, `literal`, `context`, and
    # `limit` switches. pi's default implementation shells out to the `rg` binary
    # (auto-downloaded) for the search and .gitignore handling; that pulls an
    # external Rust tool, which breaks the zero-dependency and offline
    # constraints, so this port scans the tree natively with Ruby's Regexp and
    # reuses Find (and through it Gitignore) for the file walk, so the same
    # exclusions apply. pi's TUI call and result rendering are out of scope.
    def self.grep(cwd: Dir.pwd)
      Tool.define("grep", GREP_DESCRIPTION) do
        param :pattern, :string, "Search pattern (regex or literal string)", required: true
        param :path, :string, "Directory or file to search (default: current directory)",
              required: false
        param :glob, :string, "Filter files by glob pattern, e.g. '*.rb' or '**/*.spec.rb'",
              required: false
        param :ignoreCase, :boolean, "Case-insensitive search (default: false)", required: false
        param :literal, :boolean, "Treat pattern as a literal string, not a regex (default: false)",
              required: false
        param :context, :number, "Number of lines to show before and after each match (default: 0)",
              required: false
        param :limit, :number, "Maximum number of matches to return (default: 100)", required: false
        # The model-facing keys mirror pi's schema (camelCase ignoreCase); read
        # them from the args hash so the block keeps snake_case names internally.
        run do |**args|
          Grep.run(pattern: args[:pattern], path: args[:path], glob: args[:glob],
                   ignore_case: args[:ignoreCase], literal: args[:literal],
                   context: args[:context], limit: args[:limit], cwd: cwd)
        end
      end
    end
  end
end
