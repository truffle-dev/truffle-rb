# frozen_string_literal: true

require "test_helper"
require "stringio"

# Tests for the `truffle` binary entry point (Truffle::CLI.run): the thin
# dispatcher that parses argv, surfaces diagnostics, and acts on the terminal
# flags the harness supports today.
class TestCLIRunner < Minitest::Test
  def run_cli(argv)
    out = StringIO.new
    err = StringIO.new
    status = Truffle::CLI.run(argv, out: out, err: err)
    [status, out.string, err.string]
  end

  def test_version_flag_prints_version_text_and_exits_zero
    status, out, err = run_cli(["--version"])

    assert_equal 0, status
    assert_equal "#{Truffle::CLI.version_text}\n", out
    assert_empty err
  end

  def test_help_flag_prints_help_and_exits_zero
    status, out, err = run_cli(["--help"])

    assert_equal 0, status
    assert_includes out, "truffle - AI coding assistant"
    assert_includes out, "Options:"
    assert_empty err
  end

  def test_help_to_a_non_tty_stream_has_no_ansi_escapes
    _status, out, = run_cli(["-h"])

    refute_includes out, "\e["
  end

  def test_unknown_short_flag_reports_an_error_and_exits_one
    status, out, err = run_cli(["-z"])

    assert_equal 1, status
    assert_includes err, "Error: Unknown option: -z"
    assert_empty out
  end

  def test_a_warning_diagnostic_does_not_force_a_nonzero_exit_by_itself
    # --thinking with an invalid level warns but does not error, so the run
    # falls through to the not-yet-implemented interactive path.
    status, _out, err = run_cli(["--thinking", "bogus"])

    assert_includes err, "Warning:"
    refute_includes err, "Error:"
    assert_equal Truffle::CLI::EXIT_NOT_IMPLEMENTED, status
  end

  def test_an_error_short_circuits_before_version_is_printed
    status, out, err = run_cli(["-z", "--version"])

    assert_equal 1, status
    assert_includes err, "Error: Unknown option: -z"
    refute_includes out, Truffle::VERSION
  end

  def test_version_takes_precedence_over_help
    status, out, = run_cli(["--help", "--version"])

    assert_equal 0, status
    assert_equal "#{Truffle::CLI.version_text}\n", out
    refute_includes out, "Options:"
  end

  def test_no_actionable_flag_reports_the_unimplemented_repl
    status, out, err = run_cli([])

    assert_equal Truffle::CLI::EXIT_NOT_IMPLEMENTED, status
    assert_includes err, "truffle: interactive mode is not implemented yet"
    assert_empty out
  end
end
