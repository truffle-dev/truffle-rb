# frozen_string_literal: true

require "tmpdir"
require "securerandom"
require_relative "truncate"

module Truffle
  module Tools
    # Incrementally accumulates streaming output with bounded memory. A port of
    # pi's coding-agent `output-accumulator.ts`.
    #
    # The bash tool cannot hold a whole child process's output in memory: a
    # command that prints without bound would grow the agent's heap without
    # limit. This class takes that output one raw chunk at a time, keeps only a
    # decoded rolling tail large enough to satisfy a truncated snapshot, counts
    # lines and bytes as they stream past, and spills the full, untouched output
    # to a temp file once it grows past the display limits. A #snapshot reports
    # the tail the model should see plus the truncation bookkeeping, computed from
    # the running totals rather than from the bounded tail alone.
    #
    # Faithful to pi, the temp file holds the raw bytes exactly as received: no
    # ANSI stripping, binary sanitizing, or carriage-return removal happens here.
    # Wiring this into the bash tool (which today cleans its whole buffered
    # output) is a separate slice; see the follow-up on the porting issue.
    class OutputAccumulator
      # Raised when output is appended after the accumulator has been finished.
      # pi throws a generic Error at the same point.
      class Error < StandardError
      end

      # A point-in-time view of the accumulated output: the (possibly truncated)
      # tail the model reads, the truncation bookkeeping, and the temp-file path
      # when the full output has been spilled. Mirrors pi's OutputSnapshot.
      Snapshot = Struct.new(:content, :truncation, :full_output_path, keyword_init: true)

      # pi's OutputAccumulator defaults the temp-file prefix to "pi-output" and the
      # bash tool passes "pi-bash". This port keeps the repo's own naming (see the
      # bash tool's "truffle-bash" temp files), so unwired output spills under
      # "truffle-output" rather than leaking "pi" into a filename.
      DEFAULT_TEMP_FILE_PREFIX = "truffle-output"

      def initialize(max_lines: Truncate::DEFAULT_MAX_LINES,
                     max_bytes: Truncate::DEFAULT_MAX_BYTES,
                     temp_file_prefix: DEFAULT_TEMP_FILE_PREFIX)
        @max_lines = max_lines
        @max_bytes = max_bytes
        # The rolling tail is kept at ~2x the display byte limit and only trimmed
        # once it grows past 2x that, so a truncated snapshot always has enough
        # tail to work from. pi's maxRollingBytes = max(maxBytes * 2, 1).
        @max_rolling_bytes = [@max_bytes * 2, 1].max
        @temp_file_prefix = temp_file_prefix

        @pending = String.new(encoding: Encoding::BINARY)
        @raw_chunks = []
        @tail_text = String.new(encoding: Encoding::UTF_8)
        @tail_bytes = 0
        @tail_starts_at_line_boundary = true
        @total_raw_bytes = 0
        @total_decoded_bytes = 0
        @completed_lines = 0
        @total_lines = 0
        @current_line_bytes = 0
        @has_open_line = false
        @finished = false
        @temp_file_path = nil
        @temp_file = nil
      end

      # Append one raw output chunk. The chunk is decoded into the rolling tail
      # (see #decode_stream for how a multibyte character split across chunks is
      # held), counted, and either buffered in memory or, once the output has
      # grown past the display limits, written straight to the temp file. Raising
      # after #finish matches pi rejecting a late append.
      def append(data)
        raise Error, "Cannot append to a finished output accumulator" if @finished

        data = data.b
        @total_raw_bytes += data.bytesize
        append_decoded_text(decode_stream(data))

        if @temp_file || should_use_temp_file?
          ensure_temp_file
          @temp_file.write(data)
        elsif !data.empty?
          @raw_chunks << data
        end
      end

      # Mark the stream complete: flush any bytes the streaming decoder was
      # holding for a possible continuation, and open the temp file if the final
      # totals crossed a limit. Idempotent, as in pi.
      def finish
        return if @finished

        @finished = true
        append_decoded_text(decode_flush)
        ensure_temp_file if should_use_temp_file?
      end

      # Build a snapshot of the output so far. The tail is truncated with the same
      # Truncate.tail the bash tool uses, but whether the output counts as
      # truncated (and by what) comes from the running totals, not the bounded
      # tail: the tail on its own can fit even when the whole output did not.
      # When asked, a truncated snapshot spills to the temp file so the full
      # output has a home. Mirrors pi's snapshot.
      def snapshot(persist_if_truncated: false)
        tail = Truncate.tail(snapshot_text, max_lines: @max_lines, max_bytes: @max_bytes)
        truncated = @total_lines > @max_lines || @total_decoded_bytes > @max_bytes
        truncated_by =
          if truncated
            tail.truncated_by || (@total_decoded_bytes > @max_bytes ? "bytes" : "lines")
          end

        truncation = Truncate::Result.new(
          **tail.to_h,
          truncated: truncated,
          truncated_by: truncated_by,
          total_lines: @total_lines,
          total_bytes: @total_decoded_bytes,
          max_lines: @max_lines,
          max_bytes: @max_bytes
        )

        ensure_temp_file if persist_if_truncated && truncated

        Snapshot.new(content: truncation.content, truncation: truncation,
                     full_output_path: @temp_file_path)
      end

      # Close the temp-file handle if one is open. pi returns a promise here; this
      # port is synchronous, so it just closes the handle.
      def close_temp_file
        return unless @temp_file

        @temp_file.close
        @temp_file = nil
      end

      # The byte length of the line still being built (the text after the last
      # newline). The bash tool's partial-last-line truncation notice reads this.
      # Mirrors pi's getLastLineBytes.
      def last_line_bytes
        @current_line_bytes
      end

      private

      # Fold a decoded string into the rolling tail and the counters. Trims the
      # tail once it grows past twice the rolling budget, counts the newlines the
      # string added, and tracks the open (unterminated) final line so total_lines
      # counts it exactly as pi does.
      def append_decoded_text(text)
        return if text.empty?

        bytes = text.bytesize
        @total_decoded_bytes += bytes
        @tail_text += text
        @tail_bytes += bytes
        trim_tail if @tail_bytes > @max_rolling_bytes * 2

        newlines = text.count("\n")
        if newlines.zero?
          @current_line_bytes += bytes
          @has_open_line = true
        else
          @completed_lines += newlines
          tail = text[(text.rindex("\n") + 1)..]
          @current_line_bytes = tail.bytesize
          @has_open_line = !tail.empty?
        end
        @total_lines = @completed_lines + (@has_open_line ? 1 : 0)
      end

      # Trim the rolling tail back to the rolling budget, stepping forward off any
      # UTF-8 continuation byte so the cut lands on a character boundary. Records
      # whether the trimmed tail now starts mid-line, so #snapshot_text can drop
      # the leading partial line. Mirrors pi's trimTail.
      def trim_tail
        buffer = @tail_text.b
        if buffer.bytesize <= @max_rolling_bytes
          @tail_bytes = buffer.bytesize
          return
        end

        start = buffer.bytesize - @max_rolling_bytes
        start += 1 while start < buffer.bytesize && (buffer.getbyte(start) & 0xC0) == 0x80
        @tail_starts_at_line_boundary =
          start.zero? ? @tail_starts_at_line_boundary : buffer.getbyte(start - 1) == 0x0A
        @tail_text = buffer.byteslice(start..).force_encoding("UTF-8")
        @tail_bytes = @tail_text.bytesize
      end

      # The tail to truncate for a snapshot. When trimming left the tail starting
      # inside a line, drop that leading partial line so the snapshot begins on a
      # whole line. Mirrors pi's getSnapshotText.
      def snapshot_text
        return @tail_text if @tail_starts_at_line_boundary

        newline = @tail_text.index("\n")
        newline.nil? ? @tail_text : @tail_text[(newline + 1)..]
      end

      def should_use_temp_file?
        @total_raw_bytes > @max_bytes ||
          @total_decoded_bytes > @max_bytes ||
          @total_lines > @max_lines
      end

      # Open the temp file (once), flushing any raw chunks buffered in memory into
      # it and handing future appends straight through. The file holds raw bytes.
      # Mirrors pi's ensureTempFile.
      def ensure_temp_file
        return if @temp_file_path

        @temp_file_path = File.join(Dir.tmpdir, "#{@temp_file_prefix}-#{SecureRandom.hex(8)}.log")
        @temp_file = File.open(@temp_file_path, "wb")
        @raw_chunks.each { |chunk| @temp_file.write(chunk) }
        @raw_chunks = []
      end

      # Decode as much of the buffered raw bytes as forms complete UTF-8, holding
      # back only an incomplete trailing sequence for the next chunk. This is the
      # Ruby stand-in for Node's incremental TextDecoder (decode(data, stream:
      # true)): Ruby has no streaming decoder, so a multibyte character split
      # across two reads is reassembled here rather than scrubbed into two
      # replacement characters. Bytes that are invalid rather than merely
      # incomplete are replaced with U+FFFD by #scrub, matching Node's
      # non-fatal decoder.
      def decode_stream(data)
        @pending << data
        hold = incomplete_tail_length(@pending)
        ready = @pending.byteslice(0, @pending.bytesize - hold)
        @pending = if hold.zero?
                     String.new(encoding: Encoding::BINARY)
                   else
                     @pending.byteslice(-hold,
                                        hold)
                   end
        ready.force_encoding(Encoding::UTF_8).scrub
      end

      # Flush whatever the streaming decoder was holding at end of stream. A
      # genuinely incomplete trailing sequence has no continuation coming, so it
      # is scrubbed to U+FFFD. Mirrors decoder.decode() with no argument.
      def decode_flush
        return "" if @pending.empty?

        remaining = @pending
        @pending = String.new(encoding: Encoding::BINARY)
        remaining.force_encoding(Encoding::UTF_8).scrub
      end

      # The number of trailing bytes that begin, but do not complete, a UTF-8
      # sequence, so they should wait for the next chunk. Walks back over up to
      # three continuation bytes to the lead byte, reads the length the lead
      # promises, and holds the run only when fewer bytes are present than
      # promised. Anything else (a complete character, or a byte that is not a
      # valid lead) holds nothing and is left for #scrub.
      def incomplete_tail_length(buffer)
        len = buffer.bytesize
        return 0 if len.zero?

        i = len - 1
        steps = 0
        while i.positive? && steps < 3 && (buffer.getbyte(i) & 0xC0) == 0x80
          i -= 1
          steps += 1
        end

        expected = utf8_sequence_length(buffer.getbyte(i))
        return 0 if expected.zero?

        have = len - i
        have < expected ? have : 0
      end

      # The total byte length of the UTF-8 sequence a lead byte introduces, or 0
      # when the byte is a continuation byte or otherwise not a valid lead.
      def utf8_sequence_length(byte)
        if    byte.nobits?(0x80) then 1
        elsif (byte & 0xE0) == 0xC0 then 2
        elsif (byte & 0xF0) == 0xE0 then 3
        elsif (byte & 0xF8) == 0xF0 then 4
        else 0
        end
      end
    end
  end
end
