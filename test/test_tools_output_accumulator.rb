# frozen_string_literal: true

require "test_helper"

# The OutputAccumulator, ported from pi's coding-agent output-accumulator.ts. It
# takes streaming output one raw chunk at a time, keeps a bounded decoded tail,
# counts lines and bytes, and spills the full raw output to a temp file once the
# display limits are crossed. Small limits are injected so truncation and
# spillover can be exercised without megabytes of data. Any temp file a test
# spills is removed in teardown.
class TestToolsOutputAccumulator < Minitest::Test
  Accumulator = Truffle::Tools::OutputAccumulator

  def setup
    @spilled = []
  end

  def teardown
    @spilled.each { |path| File.delete(path) if path && File.exist?(path) }
  end

  # Snapshot, remembering any temp file so teardown can clean it up.
  def snap(acc, **opts)
    result = acc.snapshot(**opts)
    @spilled << result.full_output_path if result.full_output_path
    result
  end

  def test_small_output_is_returned_whole_and_not_truncated
    acc = Accumulator.new
    acc.append("hello\nworld\n")
    acc.finish
    result = snap(acc)

    assert_equal "hello\nworld\n", result.content
    refute result.truncation.truncated
    assert_nil result.truncation.truncated_by
    assert_nil result.full_output_path
  end

  def test_counts_lines_and_open_line_bytes
    acc = Accumulator.new
    acc.append("one\ntwo\nthr")
    acc.finish

    assert_equal 3, snap(acc).truncation.total_lines
    assert_equal 3, acc.last_line_bytes
  end

  def test_trailing_newline_does_not_count_an_extra_line
    acc = Accumulator.new
    acc.append("a\nb\n")
    acc.finish

    assert_equal 2, snap(acc).truncation.total_lines
    assert_equal 0, acc.last_line_bytes
  end

  def test_total_bytes_counts_all_decoded_output
    acc = Accumulator.new
    acc.append("abc")
    acc.append("de")
    acc.finish

    assert_equal 5, snap(acc).truncation.total_bytes
  end

  def test_multibyte_character_split_across_two_appends_is_reassembled
    euro = "\u20AC" # three UTF-8 bytes: E2 82 AC
    bytes = euro.b
    acc = Accumulator.new
    acc.append(bytes.byteslice(0, 1)) # E2 alone: incomplete, held back
    acc.append(bytes.byteslice(1, 2)) # 82 AC: completes the character
    acc.finish

    assert_equal euro, snap(acc).content
    refute_includes snap(acc).content, "\uFFFD"
  end

  def test_incomplete_final_multibyte_sequence_is_scrubbed_on_finish
    acc = Accumulator.new
    acc.append("ok".b + "\xE2".b) # trailing lead byte with no continuation coming
    acc.finish

    assert_equal "ok\uFFFD", snap(acc).content
  end

  def test_invalid_byte_is_scrubbed_not_held
    acc = Accumulator.new
    acc.append("a".b + "\x80".b + "b".b) # lone continuation byte in the middle
    acc.finish

    assert_equal "a\uFFFDb", snap(acc).content
  end

  def test_line_limit_truncation_reports_truncated_by_lines
    acc = Accumulator.new(max_lines: 2)
    acc.append("l1\nl2\nl3\nl4\n")
    acc.finish
    result = snap(acc)

    assert result.truncation.truncated
    assert_equal "lines", result.truncation.truncated_by
    assert_equal 4, result.truncation.total_lines
    assert_equal "l3\nl4", result.content
  end

  def test_byte_limit_truncation_reports_truncated_by_bytes
    acc = Accumulator.new(max_bytes: 4)
    acc.append("aaaa\nbbbb\ncccc\n")
    acc.finish
    result = snap(acc)

    assert result.truncation.truncated
    assert_equal "bytes", result.truncation.truncated_by
  end

  def test_persist_if_truncated_spills_to_a_temp_file
    acc = Accumulator.new(max_lines: 1)
    acc.append("first\nsecond\nthird\n")
    acc.finish
    result = snap(acc, persist_if_truncated: true)

    refute_nil result.full_output_path
    assert_path_exists result.full_output_path
  end

  def test_persist_if_truncated_does_not_spill_when_output_fits
    acc = Accumulator.new
    acc.append("small\n")
    acc.finish

    assert_nil snap(acc, persist_if_truncated: true).full_output_path
  end

  def test_temp_file_holds_the_raw_uncleaned_bytes
    raw = "\e[31mred\e[0m\n\x00\nplain\nmore\n" # ANSI + a null byte
    acc = Accumulator.new(max_lines: 1)
    acc.append(raw)
    acc.finish
    result = snap(acc, persist_if_truncated: true)
    acc.close_temp_file # flush the handle before reading, as pi does

    assert_equal raw.b, File.binread(result.full_output_path)
  end

  def test_buffered_chunks_are_flushed_into_the_temp_file_in_order
    acc = Accumulator.new(max_bytes: 6)
    acc.append("aaa\n") # under the limit, buffered in memory
    acc.append("bbbbbbbb\n") # crosses the limit, opens the temp file
    acc.finish
    result = snap(acc, persist_if_truncated: true)
    acc.close_temp_file

    assert_equal "aaa\nbbbbbbbb\n".b, File.binread(result.full_output_path)
  end

  def test_finished_accumulator_rejects_further_appends
    acc = Accumulator.new
    acc.append("x")
    acc.finish

    assert_raises(Accumulator::Error) { acc.append("more") }
  end

  def test_finish_is_idempotent
    acc = Accumulator.new
    acc.append("x")
    acc.finish
    acc.finish # must not raise

    assert_equal "x", snap(acc).content
  end

  def test_close_temp_file_closes_the_handle
    acc = Accumulator.new(max_lines: 1)
    acc.append("a\nb\nc\n")
    acc.finish
    result = snap(acc, persist_if_truncated: true)
    acc.close_temp_file

    # The spilled content is still on disk after the handle is closed.
    assert_path_exists result.full_output_path
  end

  def test_rolling_tail_trim_drops_the_leading_partial_line
    # max_bytes 6 -> rolling budget 12, trimmed once the tail passes 24 bytes.
    # A long head line then short lines forces the trim to cut mid-head-line; the
    # snapshot must not show that partial fragment.
    acc = Accumulator.new(max_bytes: 6)
    acc.append("0123456789ABCDEFGHIJ\nfoo\nbar\n")
    acc.finish
    content = snap(acc).content

    refute_includes content, "0123"
    refute_includes content, "HIJ"
  end

  def test_partial_line_drop_and_byte_fallback_survive_a_tail_that_fits_after_the_drop
    # A head line longer than the byte limit forces the rolling trim to cut
    # inside it, leaving the tail starting mid-line. After the partial fragment
    # is dropped, the remaining tail ("keepme\n") fits the byte limit, so
    # Truncate.tail returns it whole rather than trimming further. That isolates
    # two of the accumulator's own guards: the snapshot_text partial-line drop
    # (the head fragment must not appear) and the total-driven truncated_by
    # fallback (the tail alone is not truncated, so "bytes" can only come from
    # the running totals).
    acc = Accumulator.new(max_bytes: 10)
    acc.append("#{"H" * 35}\nkeepme\n")
    acc.finish
    result = snap(acc)

    assert_includes result.content, "keepme"
    refute_includes result.content, "H"
    assert result.truncation.truncated
    assert_equal "bytes", result.truncation.truncated_by
  end
end
