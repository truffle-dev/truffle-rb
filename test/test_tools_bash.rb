# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

# The bash built-in tool, ported from pi's bash.ts, plus the Truncate.tail unit
# coverage it relies on. Commands run real bash in a temp dir so the suite stays
# hermetic; truncation behaviour is exercised both end to end (with real output
# volumes, since the byte notice hardcodes the default limit) and directly on
# Truncate.tail with small injected limits.
class TestToolsBash < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("truffle-bash")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def bash_tool
    Truffle::Tools.bash(cwd: @dir)
  end

  def test_schema_advertises_command_required_and_timeout_optional
    schema = bash_tool.to_schema

    assert_equal "bash", schema[:name]
    assert_equal %w[command], schema[:parameters][:required]
    props = schema[:parameters][:properties]

    assert_equal "string", props["command"][:type]
    assert_equal "number", props["timeout"][:type]
  end

  def test_runs_a_simple_command
    # The raw output is returned verbatim, including echo's trailing newline; pi
    # does not trim in the execute path.
    out = bash_tool.call("command" => "echo hello")

    assert_equal "hello\n", out
  end

  def test_combines_stdout_and_stderr_in_order
    # stdout and stderr are merged into one stream, in command order, the way
    # pi spawns the shell with the two pipes joined.
    out = bash_tool.call("command" => "printf 'a\\n'; printf 'b\\n' >&2")

    assert_equal "a\nb\n", out
  end

  def test_runs_in_the_bound_working_directory
    File.write(File.join(@dir, "marker.txt"), "from cwd")

    out = bash_tool.call("command" => "cat marker.txt")

    assert_equal "from cwd", out
  end

  def test_nonzero_exit_raises_with_code_and_output
    error = assert_raises(RuntimeError) do
      bash_tool.call("command" => "echo before; exit 2")
    end

    # The raw output ("before\n") is kept, then appendStatus adds a blank line
    # before the status, so the kept newline and the separator stack up.
    assert_equal "before\n\n\nCommand exited with code 2", error.message
  end

  def test_signal_killed_command_raises_with_the_signal
    # A command whose shell is killed by a signal (here SIGKILL on its own pid)
    # has a nil exit status, so the exit-code guard alone would let it pass as a
    # success. The kept output is preserved and the status names the signal and
    # the 128 + signal exit code (137 for SIGKILL).
    error = assert_raises(RuntimeError) do
      bash_tool.call("command" => "echo before; kill -KILL $$")
    end

    assert_equal "before\n\n\nCommand terminated by signal 9 (exit code 137)", error.message
  end

  def test_missing_working_directory_raises
    tool = Truffle::Tools.bash(cwd: File.join(@dir, "does", "not", "exist"))

    error = assert_raises(RuntimeError) { tool.call("command" => "echo x") }

    assert_match(/\AWorking directory does not exist:/, error.message)
    assert_includes error.message, "Cannot execute bash commands."
  end

  def test_no_output_returns_placeholder
    out = bash_tool.call("command" => "true")

    assert_equal "(no output)", out
  end

  def test_strips_ansi_color_from_output
    # pi runs captured output through stripAnsi, so color codes never reach the
    # transcript. The \033[31m ... \033[0m wrapping is removed, leaving the text.
    out = bash_tool.call("command" => "printf '\\033[31mred\\033[0m\\n'")

    assert_equal "red\n", out
  end

  def test_drops_binary_control_characters_from_output
    # A stray C0 control (BEL, 0x07) is not an ANSI sequence, so sanitizeBinaryOutput
    # is what removes it. The surrounding letters are kept.
    out = bash_tool.call("command" => "printf 'a\\007b\\n'")

    assert_equal "ab\n", out
  end

  def test_normalizes_carriage_returns_in_output
    # sanitizeBinaryOutput keeps CR; the final .replace(/\r/g, "") is what drops it,
    # so a CRLF collapses to a single LF.
    out = bash_tool.call("command" => "printf 'a\\r\\nb\\n'")

    assert_equal "a\nb\n", out
  end

  def test_timeout_kills_the_command_and_raises
    error = assert_raises(RuntimeError) do
      bash_tool.call("command" => "sleep 5", "timeout" => 1)
    end

    assert_equal "Command timed out after 1 seconds", error.message
  end

  def test_line_truncation_keeps_the_tail_and_writes_full_output
    # 2100 lines exceeds the 2000-line limit, so the last 2000 survive and the
    # notice points at a temp file holding the whole output.
    out = bash_tool.call("command" => "seq 1 2100")

    assert_match(/^2100$/, out)
    refute_match(/^1$/, out)
    notice = out[/\[Showing lines.*\]/]

    assert_match(/\A\[Showing lines 101-2100 of 2100\. Full output: \S+\]\z/, notice)
    full_path = notice[/Full output: (\S+)\]/, 1]

    assert_path_exists full_path
    assert_equal "#{(1..2100).to_a.join("\n")}\n", File.read(full_path)
  ensure
    File.delete(full_path) if full_path && File.exist?(full_path)
  end

  def test_byte_truncation_reports_the_default_limit
    # 100 lines of 600 bytes is well under the line limit but over 50KB, so the
    # byte branch fires. Its notice hardcodes the default 50KB constant.
    out = bash_tool.call("command" => "for i in $(seq 1 100); do printf '%600d\\n' \"$i\"; done")

    notice = out[/\[Showing lines.*\]/]

    assert_match(/\(50\.0KB limit\)/, notice)
    full_path = notice[/Full output: (\S+)\]/, 1]

    assert_path_exists full_path
  ensure
    File.delete(full_path) if full_path && File.exist?(full_path)
  end

  def test_single_oversized_line_keeps_its_tail
    # One 60000-byte line with no newline overflows the byte limit on its own;
    # the end is kept and the notice names it a partial line.
    out = bash_tool.call("command" => "printf '%60000s' '' | tr ' ' z")

    notice = out[/\[Showing last.*\]/]
    expected = /\A\[Showing last 50\.0KB of line 1 \(line is 58\.6KB\)\. Full output: \S+\]\z/

    assert_match(expected, notice)
    full_path = notice[/Full output: (\S+)\]/, 1]

    assert_path_exists full_path
    assert_equal 60_000, File.size(full_path)
  ensure
    File.delete(full_path) if full_path && File.exist?(full_path)
  end

  # --- Truncate.tail unit coverage --------------------------------------------

  def test_tail_passthrough_when_within_limits
    result = Truffle::Tools::Truncate.tail("a\nb\nc")

    refute result.truncated
    assert_nil result.truncated_by
    assert_equal "a\nb\nc", result.content
    assert_equal 3, result.total_lines
  end

  def test_tail_keeps_the_last_lines_under_a_line_limit
    result = Truffle::Tools::Truncate.tail("a\nb\nc\nd\ne", max_lines: 2)

    assert result.truncated
    assert_equal "lines", result.truncated_by
    assert_equal "d\ne", result.content
    assert_equal 2, result.output_lines
    assert_equal 5, result.total_lines
  end

  def test_tail_byte_limit_counts_the_joining_newline
    # Five distinct 9-byte lines. At a 28-byte cap, the last line (9 bytes) plus
    # the next-to-last (9 + its joining newline = 10) reaches 19; a third would
    # cost another 10 and hit 29 > 28, so exactly the last two survive. Distinct
    # letters pin both the newline cost and that this keeps the TAIL, not the
    # head.
    body = %w[aaaaaaaaa bbbbbbbbb ccccccccc ddddddddd eeeeeeeee].join("\n")

    result = Truffle::Tools::Truncate.tail(body, max_bytes: 28)

    assert_equal "bytes", result.truncated_by
    assert_equal "ddddddddd\neeeeeeeee", result.content
    assert_equal 2, result.output_lines
  end

  def test_tail_keeps_the_end_of_a_single_oversized_line
    result = Truffle::Tools::Truncate.tail("z" * 60, max_bytes: 25)

    assert result.last_line_partial
    assert_equal "bytes", result.truncated_by
    assert_equal "z" * 25, result.content
    assert_equal 25, result.output_bytes
  end
end
