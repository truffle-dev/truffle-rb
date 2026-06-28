# frozen_string_literal: true

require "monitor"

module Truffle
  # A cooperative cancellation token, the Ruby stand-in for pi's AbortSignal
  # (packages/ai/src/utils/abort-signals.ts). pi runs on the browser/Node
  # AbortController, an event-driven flag threaded into fetch and into the agent
  # loop; Ruby has no built-in equivalent, so this is a small thread-safe flag
  # checked at cancellation points.
  #
  # The owner of a run holds the signal and may call #abort from any thread (a
  # UI key handler, a timeout thread, a trap). The agent loop and the streaming
  # reader check #aborted? at safe boundaries and stop cleanly with a
  # StopReason::ABORTED terminal. Cancellation is cooperative: a check happens
  # between turns and between stream fragments, not by force-closing a socket
  # mid-read.
  class AbortSignal
    DEFAULT_REASON = "aborted"

    # Build a signal that is already aborted, for tests and for short-circuiting
    # a run the caller has decided not to start.
    def self.aborted(reason = DEFAULT_REASON)
      new.tap { |s| s.abort(reason) }
    end

    def initialize
      @lock = Monitor.new
      @aborted = false
      @reason = nil
    end

    # Request cancellation. Idempotent: the first reason wins, later calls are
    # no-ops, matching how an AbortController latches on first abort.
    def abort(reason = DEFAULT_REASON)
      @lock.synchronize do
        next if @aborted

        @aborted = true
        @reason = reason
      end
      self
    end

    def aborted?
      @lock.synchronize { @aborted }
    end

    # The reason given to #abort, or nil while still live.
    def reason
      @lock.synchronize { @reason }
    end
  end
end
