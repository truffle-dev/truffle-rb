# frozen_string_literal: true

require "monitor"

module Truffle
  # A channel-based publish/subscribe seam, the Ruby port of pi's event bus
  # (packages/coding-agent/src/core/event-bus.ts). pi builds it on Node's
  # EventEmitter and hands it to extensions as `pi.events` so independently
  # loaded extensions can talk to each other without holding direct references.
  #
  # The shape is deliberately tiny: #emit fans a payload out to every handler
  # subscribed to a channel, #on subscribes and returns an unsubscribe closure,
  # and #clear drops every subscription. Two faithful behaviors carry over from
  # pi:
  #
  # - A handler that raises is isolated. The error is reported and the remaining
  #   handlers on the channel still run; the failure never propagates back into
  #   #emit. pi does this so one misbehaving extension cannot break the bus for
  #   the others.
  # - #emit iterates over a snapshot of the channel's handlers, so a handler that
  #   subscribes or unsubscribes while it runs does not disturb the in-flight
  #   dispatch. This matches EventEmitter, which copies its listener array before
  #   calling.
  #
  # pi's handlers are async and awaited one at a time; Ruby handlers are plain
  # callables invoked in subscription order. The bus is guarded by a Monitor so
  # emit/on/clear are safe to call from multiple threads, since a host may emit
  # from a UI thread while the agent loop subscribes from another.
  class EventBus
    # Build a bus. +logger+ receives a single string when a handler raises; it
    # defaults to $stderr (matching pi's console.error) and can be swapped for a
    # capturing object in tests. It only needs to respond to #puts.
    def initialize(logger: $stderr)
      @lock = Monitor.new
      @channels = {}
      @logger = logger
    end

    # Publish +data+ to every handler subscribed to +channel+. Handlers run in
    # subscription order over a snapshot taken under the lock, so subscribing or
    # unsubscribing from inside a handler is safe. A handler that raises is
    # reported through the logger and does not stop the others or reach the
    # caller. Returns self.
    def emit(channel, data = nil)
      handlers = @lock.synchronize { (@channels[channel] || []).dup }
      handlers.each do |entry|
        entry.handler.call(data)
      rescue StandardError => e
        @logger.puts("Event handler error (#{channel}): #{e.class}: #{e.message}")
      end
      self
    end

    # Subscribe +handler+ (or a block) to +channel+ and return a callable that
    # removes exactly this subscription when invoked. Unsubscribing is
    # idempotent: calling the returned closure more than once is a no-op, and the
    # same callable may be subscribed several times, each registration unwound
    # independently by its own closure.
    def on(channel, handler = nil, &block)
      callable = handler || block
      raise ArgumentError, "on requires a handler or a block" unless callable

      entry = Subscription.new(callable)
      @lock.synchronize { (@channels[channel] ||= []) << entry }

      lambda do
        @lock.synchronize do
          list = @channels[channel]
          next unless list

          list.delete(entry)
          @channels.delete(channel) if list.empty?
        end
        nil
      end
    end

    # Drop every subscription on every channel.
    def clear
      @lock.synchronize { @channels.clear }
      self
    end

    # Wraps a handler so each registration has its own identity, letting the same
    # callable be subscribed (and later removed) more than once.
    class Subscription
      attr_reader :handler

      def initialize(handler)
        @handler = handler
      end
    end
    private_constant :Subscription
  end
end
