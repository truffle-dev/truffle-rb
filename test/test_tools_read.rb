# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

# The read built-in tool and its Truncate dependency, ported from pi's
# coding-agent. Files are written into a temp dir so the suite stays hermetic.
class TestToolsRead < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("truffle-read")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def write(name, content)
    path = File.join(@dir, name)
    File.write(path, content)
    path
  end

  def read_tool(**opts)
    Truffle::Tools.read(cwd: @dir, **opts)
  end

  def test_schema_advertises_path_offset_limit
    schema = read_tool.to_schema

    assert_equal "read", schema[:name]
    assert_equal %w[path], schema[:parameters][:required]
    props = schema[:parameters][:properties]

    assert_equal "string", props["path"][:type]
    assert_equal "integer", props["offset"][:type]
    assert_equal "integer", props["limit"][:type]
  end

  def test_reads_whole_file_relative_to_cwd
    write("hello.txt", "alpha\nbeta\ngamma\n")

    assert_equal "alpha\nbeta\ngamma\n", read_tool.call("path" => "hello.txt")
  end

  def test_reads_absolute_path
    path = write("abs.txt", "one\ntwo\n")

    assert_equal "one\ntwo\n", read_tool.call("path" => path)
  end

  def test_offset_is_one_indexed
    write("nums.txt", "l1\nl2\nl3\nl4\n")

    # offset 3 starts at the third line, not the fourth.
    assert_equal "l3\nl4\n", read_tool.call("path" => "nums.txt", "offset" => 3)
  end

  def test_limit_caps_lines_and_reports_remaining
    write("many.txt", "a\nb\nc\nd\ne\n")

    out = read_tool.call("path" => "many.txt", "limit" => 2)

    assert_match(/\Aa\nb\n\n/, out)
    assert_includes out, "[4 more lines in file. Use offset=3 to continue.]"
  end

  def test_offset_and_limit_together
    write("grid.txt", "r1\nr2\nr3\nr4\nr5\n")

    out = read_tool.call("path" => "grid.txt", "offset" => 2, "limit" => 2)

    assert_match(/\Ar2\nr3\n/, out)
    assert_includes out, "Use offset=4 to continue."
  end

  def test_limit_reaching_end_has_no_continuation_notice
    write("two.txt", "x\ny\n")

    out = read_tool.call("path" => "two.txt", "limit" => 5)

    refute_includes out, "more lines in file"
    refute_includes out, "Use offset"
  end

  def test_offset_beyond_end_raises_with_total_lines
    write("short.txt", "only\n")
    # "only\n" splits to ["only", ""] -> 2 lines, faithful to pi's allLines.

    error = assert_raises(RuntimeError) do
      read_tool.call("path" => "short.txt", "offset" => 9)
    end
    assert_equal "Offset 9 is beyond end of file (2 lines total)", error.message
  end

  def test_line_truncation_builds_showing_lines_notice
    body = (1..10).map { |i| "line#{i}" }.join("\n")
    write("big.txt", body)

    out = Truffle::Tools.read(cwd: @dir, max_lines: 3).call("path" => "big.txt")

    assert_match(/\Aline1\nline2\nline3\n\n/, out)
    assert_includes out, "[Showing lines 1-3 of 10. Use offset=4 to continue.]"
  end

  def test_byte_truncation_builds_limit_notice
    # Five 9-char lines joined by newlines. At a 28-byte cap, keeping line 1 (9
    # bytes) plus line 2 (9 + its joining newline = 10) reaches 19; a third line
    # would cost another 10 and hit 29 > 28, so exactly two lines survive. The
    # joining-newline byte is load-bearing: without it three lines would fit, so
    # the 1-2 line range here pins that the newline cost is counted.
    write("bytes.txt", Array.new(5) { "x" * 9 }.join("\n"))

    out = Truffle::Tools.read(cwd: @dir, max_bytes: 28).call("path" => "bytes.txt")

    assert_match(/\Axxxxxxxxx\nxxxxxxxxx\n\n/, out)
    assert_includes out, "[Showing lines 1-2 of 5 (28B limit). Use offset=3 to continue.]"
  end

  def test_first_line_exceeds_byte_limit_points_at_bash
    write("huge.txt", "#{"z" * 100}\nnext\n")

    out = Truffle::Tools.read(cwd: @dir, max_bytes: 10).call("path" => "huge.txt")

    assert_match(/\A\[Line 1 is 100B, exceeds 10B limit\./, out)
    assert_includes out, "sed -n '1p' huge.txt | head -c 10"
  end

  def test_missing_file_raises_system_call_error
    assert_raises(Errno::ENOENT) do
      read_tool.call("path" => "nope.txt")
    end
  end

  # --- Truncate unit coverage -------------------------------------------------

  def test_truncate_passthrough_when_within_limits
    result = Truffle::Tools::Truncate.head("a\nb\nc")

    refute result.truncated
    assert_nil result.truncated_by
    assert_equal "a\nb\nc", result.content
    assert_equal 3, result.total_lines
  end

  def test_truncate_counts_trailing_newline_like_pi
    # "a\nb\n" is two lines, not three: the trailing newline's empty is dropped.
    result = Truffle::Tools::Truncate.head("a\nb\n")

    assert_equal 2, result.total_lines
  end

  def test_format_size_thresholds
    mod = Truffle::Tools::Truncate

    assert_equal "512B", mod.format_size(512)
    assert_equal "1.5KB", mod.format_size(1536)
    assert_equal "2.0MB", mod.format_size(2 * 1024 * 1024)
  end
end
