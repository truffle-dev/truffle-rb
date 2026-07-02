# frozen_string_literal: true

require "open3"
require "monitor"

module Truffle
  # Run an external program and capture its output, the Ruby port of pi's
  # coding-agent exec.ts (packages/coding-agent/src/core/exec.ts). pi exposes it
  # to extensions and custom tools as the way to shell out to a program under a
  # timeout and a cancellation signal.
  #
  # Unlike the bash tool, this runs a program directly from an argument list with
  # no shell: `command` is the executable and `args` are passed verbatim, so
  # nothing in a caller-supplied argument is reinterpreted by a shell. stdout and
  # stderr are captured separately. A run can be bounded two ways and both end the
  # same: a `timeout_ms` deadline, or an aborted `signal`. On either, the process
  # is sent SIGTERM, then SIGKILL if it is still alive five seconds later,
  # matching pi's escalation. The result carries the captured streams, the exit
  # code, and whether the process was killed.
  #
  # The exit code mirrors pi's `code ?? 0`: a normal exit reports its status, a
  # process ended by a signal (a kill) reports 0 with `killed` set, and a program
  # that cannot be spawned at all reports 1. Wiring this into the extension and
  # custom-tool runtimes is a follow-up; this module ports the executor itself.
  #
  # A detached descendant that inherits and holds a pipe open past the parent's
  # exit can keep the readers blocking (earendil-works/pi#5303); pi handles that
  # with a post-exit idle grace. This port reads each stream to EOF, which covers
  # the common case; the descendant-pipe grace is a later refinement.
  module Exec
    # After a kill signal, wait this long for a graceful SIGTERM exit before
    # escalating to SIGKILL. pi's 5000ms.
    SIGKILL_GRACE_SECONDS = 5

    # How often the watcher rechecks the deadline and the abort signal.
    POLL_INTERVAL_SECONDS = 0.02

    # The outcome of a run: the captured streams, the exit code (see the module
    # note on `code ?? 0` semantics), and whether the process was killed by a
    # timeout or an abort. Port of pi's ExecResult.
    Result = Struct.new(:stdout, :stderr, :code, :killed, keyword_init: true)

    module_function

    # Run `command` with `args` in `cwd`, returning a Result. `signal` is an
    # AbortSignal polled for cancellation; `timeout_ms` is a millisecond deadline.
    # A command that cannot be spawned resolves to code 1 rather than raising,
    # matching pi resolving its promise on the child-process error.
    def command(command, args = [], cwd:, signal: nil, timeout_ms: nil)
      stdin, out_io, err_io, wait_thr = Open3.popen3(command, *args, chdir: cwd)
      stdin.close
      out_reader = Thread.new { out_io.read }
      err_reader = Thread.new { err_io.read }
      killer = Killer.new(wait_thr)
      watcher = start_watcher(wait_thr, signal, timeout_ms, killer)

      status = wait_thr.value
      watcher.kill
      watcher.join
      build_result(out_reader.value, err_reader.value, status, killer.killed?)
    rescue SystemCallError
      Result.new(stdout: "", stderr: "", code: 1, killed: false)
    end

    # The watcher thread: it kills the process when the abort signal trips or the
    # deadline passes, and exits on its own once the process is gone. pi arms a
    # timeout timer and an abort listener; Ruby's AbortSignal is poll-based, so
    # this checks both on a short interval.
    def start_watcher(wait_thr, signal, timeout_ms, killer)
      deadline = deadline_for(timeout_ms)
      Thread.new do
        while wait_thr.alive?
          if signal&.aborted? || (deadline && monotonic_now >= deadline)
            killer.kill
            break
          end
          sleep POLL_INTERVAL_SECONDS
        end
      end
    end

    # The monotonic instant a timeout expires, or nil when there is no positive
    # timeout to enforce.
    def deadline_for(timeout_ms)
      return nil unless timeout_ms&.positive?

      monotonic_now + (timeout_ms / 1000.0)
    end

    # Assemble the Result from the captured output and the process status. A
    # process ended by a signal has a nil exitstatus; pi's `code ?? 0` reports
    # that as 0, with the kill recorded separately in `killed`.
    def build_result(stdout, stderr, status, killed)
      Result.new(
        stdout: stdout || "",
        stderr: stderr || "",
        code: status.exitstatus || 0,
        killed: killed
      )
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    private_class_method :start_watcher, :deadline_for, :build_result, :monotonic_now

    # Kills a running child once, then escalates to SIGKILL if it survives the
    # grace period, matching pi's SIGTERM-then-SIGKILL. Thread-safe: the watcher
    # thread calls #kill while the main thread reads #killed?.
    class Killer
      def initialize(wait_thr)
        @wait_thr = wait_thr
        @lock = Monitor.new
        @killed = false
      end

      def killed?
        @lock.synchronize { @killed }
      end

      # Send SIGTERM (once), then SIGKILL after the grace period if the process is
      # still alive. The SIGKILL escalation runs in its own thread so the caller
      # is never blocked; a process that has already exited is a no-op.
      def kill
        @lock.synchronize do
          return if @killed

          @killed = true
        end
        signal_process("TERM")
        Thread.new do
          sleep SIGKILL_GRACE_SECONDS
          signal_process("KILL") if @wait_thr.alive?
        end
      end

      # Signal the child by pid, ignoring the race where it has already exited.
      def signal_process(name)
        Process.kill(name, @wait_thr.pid)
      rescue SystemCallError
        nil
      end
      private :signal_process
    end
  end
end
