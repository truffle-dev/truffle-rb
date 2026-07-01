# frozen_string_literal: true

require_relative "truncate"
require_relative "path"

module Truffle
  module Tools
    READ_DESCRIPTION =
      "Read the contents of a text file. Output is truncated to " \
      "#{Truncate::DEFAULT_MAX_LINES} lines or #{Truncate::DEFAULT_MAX_BYTES / 1024}KB " \
      "(whichever is hit first). Use offset and limit for large files; when you need " \
      "the full file, continue with offset until complete."
      .freeze

    # Build pi's `read` tool, bound to a working directory. A relative `path` is
    # resolved against `cwd`; an absolute path is used as-is. `offset` is a
    # 1-indexed start line and `limit` caps the number of lines returned. Output
    # passes through Truncate.head so a large file does not flood the context, and
    # a continuation notice tells the model how to read the rest.
    #
    # max_lines/max_bytes are exposed for tests; production uses pi's defaults.
    def self.read(cwd: Dir.pwd, max_lines: Truncate::DEFAULT_MAX_LINES,
                  max_bytes: Truncate::DEFAULT_MAX_BYTES)
      Tool.define("read", READ_DESCRIPTION) do
        param :path, :string, "Path to the file to read (relative or absolute)", required: true
        param :offset, :integer, "Line number to start reading from (1-indexed)"
        param :limit, :integer, "Maximum number of lines to read"
        run do |path:, offset: nil, limit: nil|
          Truffle::Tools.read_file(path: path, cwd: cwd, offset: offset, limit: limit,
                                   max_lines: max_lines, max_bytes: max_bytes)
        end
      end
    end

    # The text-read core, a faithful port of read.ts's text path. An empty file
    # counts as one empty line because JavaScript `"".split("\n")` returns [""];
    # splitting with a limit of -1 keeps trailing empties so the line count
    # matches pi's `allLines.length` (including the trailing-newline quirk). File
    # errors (missing, unreadable) propagate as the underlying SystemCallError;
    # the agent loop reports them back to the model.
    def self.read_file(path:, cwd:, offset: nil, limit: nil,
                       max_lines: Truncate::DEFAULT_MAX_LINES, max_bytes: Truncate::DEFAULT_MAX_BYTES)
      absolute = Path.resolve(path, cwd)
      content = File.read(absolute, encoding: "UTF-8")
      all_lines = content.empty? ? [""] : content.split("\n", -1)

      start_line = offset ? [0, offset - 1].max : 0
      if start_line >= all_lines.length
        raise "Offset #{offset} is beyond end of file (#{all_lines.length} lines total)"
      end

      selected, user_limited_lines = select_lines(all_lines, start_line, limit)
      truncation = Truncate.head(selected, max_lines: max_lines, max_bytes: max_bytes)
      format_output(truncation, all_lines, start_line, user_limited_lines, path)
    end

    # Slice the requested window. With a user limit, stop at start+limit (clamped
    # to the file) and report how many lines that took so the caller can tell the
    # model whether more remains. Without a limit, take everything from the start.
    def self.select_lines(all_lines, start_line, limit)
      if limit
        effective_limit = [1, limit.to_i].max
        end_line = [start_line + effective_limit, all_lines.length].min
        [all_lines[start_line...end_line].join("\n"), end_line - start_line]
      else
        [all_lines[start_line..].join("\n"), nil]
      end
    end

    # Turn a truncation result into the text the model reads, appending the same
    # continuation notices pi builds: a byte-bounded bash fallback when one line is
    # too large, a "Showing lines X-Y of Z" notice on truncation, and a "more
    # lines in file" notice when a user limit stopped short of the end.
    def self.format_output(truncation, all_lines, start_line, user_limited_lines, path)
      start_display = start_line + 1
      total_file_lines = all_lines.length

      if truncation.first_line_exceeds_limit
        first_line_size = Truncate.format_size(all_lines[start_line].bytesize)
        limit_size = Truncate.format_size(truncation.max_bytes)
        "[Line #{start_display} is #{first_line_size}, exceeds #{limit_size} limit. " \
          "Use bash: sed -n '#{start_display}p' #{path} | head -c #{truncation.max_bytes}]"
      elsif truncation.truncated
        truncated_notice(truncation, start_display, total_file_lines)
      elsif !user_limited_lines.nil? && start_line + user_limited_lines < all_lines.length
        remaining = all_lines.length - (start_line + user_limited_lines)
        next_offset = start_line + user_limited_lines + 1
        "#{truncation.content}\n\n" \
          "[#{remaining} more lines in file. Use offset=#{next_offset} to continue.]"
      else
        truncation.content
      end
    end

    def self.truncated_notice(truncation, start_display, total_file_lines)
      end_display = start_display + truncation.output_lines - 1
      next_offset = end_display + 1
      if truncation.truncated_by == "lines"
        "#{truncation.content}\n\n[Showing lines #{start_display}-#{end_display} of " \
          "#{total_file_lines}. Use offset=#{next_offset} to continue.]"
      else
        limit_size = Truncate.format_size(truncation.max_bytes)
        "#{truncation.content}\n\n[Showing lines #{start_display}-#{end_display} of " \
          "#{total_file_lines} (#{limit_size} limit). Use offset=#{next_offset} to continue.]"
      end
    end
  end
end
