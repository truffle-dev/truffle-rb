# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class TestExec < Minitest::Test
  include Truffle

  # Each run gets a fresh temp directory to use as the working directory, so a
  # cwd assertion has a stable, isolated target.
  def setup
    @dir = Dir.mktmpdir("truffle-exec-")
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
  end

  # --- normal execution ------------------------------------------------------

  def test_captures_stdout_and_reports_success
    result = Exec.command("printf", ["hello"], cwd: @dir)

    assert_equal "hello", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.code
    refute result.killed
  end

  def test_captures_stderr_separately_from_stdout
    result = Exec.command("sh", ["-c", "printf out; printf err 1>&2"], cwd: @dir)

    assert_equal "out", result.stdout
    assert_equal "err", result.stderr
    assert_equal 0, result.code
  end

  def test_reports_nonzero_exit_code
    result = Exec.command("sh", ["-c", "exit 3"], cwd: @dir)

    assert_equal 3, result.code
    refute result.killed
  end

  def test_runs_in_the_given_cwd
    result = Exec.command("pwd", [], cwd: @dir)

    assert_equal File.realpath(@dir), result.stdout.strip
  end

  def test_passes_arguments_verbatim_without_a_shell
    # A shell would expand the glob and the $VAR; run with no shell they arrive
    # at the program untouched.
    result = Exec.command("printf", ["%s\n", "*.rb", "$HOME"], cwd: @dir)

    assert_equal "*.rb\n$HOME\n", result.stdout
  end

  # --- failure to spawn ------------------------------------------------------

  def test_missing_command_resolves_to_code_one
    result = Exec.command("truffle_no_such_program_exists", [], cwd: @dir)

    assert_equal 1, result.code
    refute result.killed
    assert_equal "", result.stdout
    assert_equal "", result.stderr
  end

  # --- timeout ---------------------------------------------------------------

  def test_timeout_kills_the_process
    started = monotonic
    result = Exec.command("sleep", ["3"], cwd: @dir, timeout_ms: 100)

    assert result.killed, "expected the timed-out process to be marked killed"
    assert_equal 0, result.code
    assert_operator monotonic - started, :<, 1, "timeout should return well before the sleep"
  end

  def test_no_timeout_lets_a_quick_command_finish
    result = Exec.command("printf", ["done"], cwd: @dir, timeout_ms: 5000)

    assert_equal "done", result.stdout
    refute result.killed
  end

  # --- abort signal ----------------------------------------------------------

  def test_already_aborted_signal_kills_immediately
    signal = AbortSignal.aborted
    started = monotonic
    result = Exec.command("sleep", ["3"], cwd: @dir, signal: signal)

    assert result.killed
    assert_operator monotonic - started, :<, 1
  end

  def test_abort_mid_run_kills_the_process
    signal = AbortSignal.new
    aborter = Thread.new do
      sleep 0.1
      signal.abort
    end

    started = monotonic
    result = Exec.command("sleep", ["3"], cwd: @dir, signal: signal)
    aborter.join

    assert result.killed
    assert_operator monotonic - started, :<, 1
  end

  def test_a_finished_command_is_not_marked_killed_by_a_live_signal
    result = Exec.command("printf", ["ok"], cwd: @dir, signal: AbortSignal.new)

    assert_equal "ok", result.stdout
    refute result.killed
  end

  private

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
