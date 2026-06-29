# frozen_string_literal: true

module Truffle
  module Tools
    # Shared truncation utilities for tool output.
    #
    # A port of pi's coding-agent `truncate.ts`. Truncation is governed by two
    # independent limits, and whichever is hit first wins: a line limit (default
    # 2000) and a byte limit (default 50KB). Output never ends on a partial line
    # for head truncation; if the very first line already exceeds the byte limit
    # the result is empty and `first_line_exceeds_limit` is set so the caller can
    # point the model at a byte-bounded fallback.
    #
    # `read` consumes `head`; `bash` consumes `tail` (keep the last lines/bytes,
    # where errors and final results live); `grep` (per-line) will share this
    # module as it lands, which is why the full result shape is ported once.
    module Truncate
      DEFAULT_MAX_LINES = 2000
      DEFAULT_MAX_BYTES = 50 * 1024 # 50KB
      GREP_MAX_LINE_LENGTH = 500 # Max chars per grep match line

      # The outcome of a single-line truncation. Mirrors pi's truncateLine return
      # shape so grep can read `text` and `truncated` without reshaping.
      LineResult = Struct.new(:text, :truncated, keyword_init: true)

      # The outcome of a truncation pass. Mirrors pi's TruncationResult so later
      # tools (bash, grep) can read the same fields without reshaping.
      Result = Struct.new(
        :content, :truncated, :truncated_by, :total_lines, :total_bytes,
        :output_lines, :output_bytes, :last_line_partial, :first_line_exceeds_limit,
        :max_lines, :max_bytes, keyword_init: true
      )

      module_function

      # Truncate from the head: keep the first lines/bytes that fit. Suitable for
      # file reads where the beginning is what matters.
      def head(content, max_lines: DEFAULT_MAX_LINES, max_bytes: DEFAULT_MAX_BYTES)
        total_bytes = content.bytesize
        lines = split_for_counting(content)
        total_lines = lines.length
        totals = { total_lines: total_lines, total_bytes: total_bytes,
                   max_lines: max_lines, max_bytes: max_bytes }

        if total_lines <= max_lines && total_bytes <= max_bytes
          return Result.new(content: content, truncated: false, truncated_by: nil,
                            output_lines: total_lines, output_bytes: total_bytes,
                            last_line_partial: false, first_line_exceeds_limit: false, **totals)
        end

        if lines[0].bytesize > max_bytes
          return Result.new(content: "", truncated: true, truncated_by: "bytes",
                            output_lines: 0, output_bytes: 0, last_line_partial: false,
                            first_line_exceeds_limit: true, **totals)
        end

        kept, _used, truncated_by = collect_head(lines, max_lines, max_bytes)
        output = kept.join("\n")
        Result.new(content: output, truncated: true, truncated_by: truncated_by,
                   output_lines: kept.length, output_bytes: output.bytesize,
                   last_line_partial: false, first_line_exceeds_limit: false, **totals)
      end

      # Truncate from the tail: keep the last lines/bytes that fit. Suitable for
      # bash output where the end (errors, final results) is what matters. Unlike
      # head, the tail can return a partial line: if the single last line already
      # exceeds the byte limit, its end is kept and last_line_partial is set.
      def tail(content, max_lines: DEFAULT_MAX_LINES, max_bytes: DEFAULT_MAX_BYTES)
        total_bytes = content.bytesize
        lines = split_for_counting(content)
        total_lines = lines.length
        totals = { total_lines: total_lines, total_bytes: total_bytes,
                   max_lines: max_lines, max_bytes: max_bytes }

        if total_lines <= max_lines && total_bytes <= max_bytes
          return Result.new(content: content, truncated: false, truncated_by: nil,
                            output_lines: total_lines, output_bytes: total_bytes,
                            last_line_partial: false, first_line_exceeds_limit: false, **totals)
        end

        kept, _used, truncated_by, partial = collect_tail(lines, max_lines, max_bytes)
        output = kept.join("\n")
        Result.new(content: output, truncated: true, truncated_by: truncated_by,
                   output_lines: kept.length, output_bytes: output.bytesize,
                   last_line_partial: partial, first_line_exceeds_limit: false, **totals)
      end

      # Truncate a single line to max characters, appending a "... [truncated]"
      # suffix when it is cut. grep uses this so one very long line does not blow
      # up the match output. Length is counted in characters, as pi counts it.
      def truncate_line(line, max_chars = GREP_MAX_LINE_LENGTH)
        return LineResult.new(text: line, truncated: false) if line.length <= max_chars

        LineResult.new(text: "#{line[0, max_chars]}... [truncated]", truncated: true)
      end

      # Format a byte count the way pi's formatSize does: "512B", "1.5KB", "2.0MB".
      def format_size(bytes)
        if bytes < 1024
          "#{bytes}B"
        elsif bytes < 1024 * 1024
          "#{format("%.1f", bytes / 1024.0)}KB"
        else
          "#{format("%.1f", bytes / (1024.0 * 1024))}MB"
        end
      end

      # Count lines the way pi does: split keeping trailing empties, then drop the
      # single empty produced by a trailing newline so "a\nb\n" counts as two
      # lines, not three. Empty content counts as zero lines.
      def split_for_counting(content)
        return [] if content.empty?

        lines = content.split("\n", -1)
        lines.pop if content.end_with?("\n")
        lines
      end

      # Walk the lines, keeping complete ones until either limit is hit. A line
      # after the first costs one extra byte for the joining newline, matching how
      # the kept lines are later rejoined with "\n".
      def collect_head(lines, max_lines, max_bytes)
        kept = []
        used = 0
        truncated_by = "lines"

        lines.each_with_index do |line, i|
          break if i >= max_lines

          line_bytes = line.bytesize + (i.positive? ? 1 : 0)
          if used + line_bytes > max_bytes
            truncated_by = "bytes"
            break
          end

          kept << line
          used += line_bytes
        end

        truncated_by = "lines" if kept.length >= max_lines && used <= max_bytes
        [kept, used, truncated_by]
      end

      # Walk the lines backwards, keeping complete ones until either limit is hit.
      # Like collect_head, a line costs one extra byte for the joining newline
      # once at least one line is already kept. If the very last line alone blows
      # the byte budget, keep only the trailing bytes of it (partial) so bash
      # output that ends in one enormous line still shows its end.
      def collect_tail(lines, max_lines, max_bytes)
        kept = []
        used = 0
        truncated_by = "lines"
        partial = false

        i = lines.length - 1
        while i >= 0 && kept.length < max_lines
          line = lines[i]
          line_bytes = line.bytesize + (kept.empty? ? 0 : 1)
          if used + line_bytes > max_bytes
            truncated_by = "bytes"
            if kept.empty?
              trimmed = bytes_from_end(line, max_bytes)
              kept.unshift(trimmed)
              used = trimmed.bytesize
              partial = true
            end
            break
          end

          kept.unshift(line)
          used += line_bytes
          i -= 1
        end

        truncated_by = "lines" if kept.length >= max_lines && used <= max_bytes
        [kept, used, truncated_by, partial]
      end

      # Keep the last max_bytes bytes of a string, stepping forward off any UTF-8
      # continuation byte so the cut lands on a character boundary (pi's
      # truncateStringToBytesFromEnd).
      def bytes_from_end(str, max_bytes)
        bytes = str.b
        return str if bytes.bytesize <= max_bytes

        start = bytes.bytesize - max_bytes
        start += 1 while start < bytes.bytesize && (bytes.getbyte(start) & 0xC0) == 0x80
        bytes.byteslice(start..).force_encoding("UTF-8")
      end
    end
  end
end
