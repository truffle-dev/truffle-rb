# frozen_string_literal: true

require_relative "test_helper"

# The channel-based pub/sub seam extensions use to talk to each other.
class TestEventBus < Minitest::Test
  def setup
    @bus = Truffle::EventBus.new(logger: CapturingLogger.new)
  end

  def test_emit_delivers_payload_to_a_subscriber
    seen = []
    @bus.on("ping") { |data| seen << data }

    @bus.emit("ping", 42)

    assert_equal [42], seen
  end

  def test_emit_to_a_channel_with_no_subscribers_is_a_noop
    assert_same @bus, @bus.emit("nobody", "x")
  end

  def test_emit_defaults_data_to_nil
    seen = :unset
    @bus.on("ping") { |data| seen = data }

    @bus.emit("ping")

    assert_nil seen
  end

  def test_a_channel_is_isolated_from_other_channels
    seen = []
    @bus.on("a") { |d| seen << "a:#{d}" }
    @bus.on("b") { |d| seen << "b:#{d}" }

    @bus.emit("a", 1)

    assert_equal ["a:1"], seen
  end

  def test_handlers_run_in_subscription_order
    order = []
    @bus.on("c") { order << :first }
    @bus.on("c") { order << :second }

    @bus.emit("c", nil)

    assert_equal %i[first second], order
  end

  def test_on_accepts_a_callable_handler
    seen = []
    handler = ->(data) { seen << data }
    @bus.on("ping", handler)

    @bus.emit("ping", "hi")

    assert_equal ["hi"], seen
  end

  def test_on_without_a_handler_or_block_raises
    assert_raises(ArgumentError) { @bus.on("ping") }
  end

  def test_unsubscribe_closure_stops_delivery
    seen = []
    off = @bus.on("ping") { |d| seen << d }

    @bus.emit("ping", 1)
    off.call
    @bus.emit("ping", 2)

    assert_equal [1], seen
  end

  def test_unsubscribe_is_idempotent
    seen = []
    off = @bus.on("ping") { |d| seen << d }
    off.call

    assert_nil off.call
    @bus.emit("ping", 1)

    assert_empty seen
  end

  def test_same_callable_subscribed_twice_is_removed_independently
    seen = []
    handler = ->(d) { seen << d }
    off1 = @bus.on("ping", handler)
    @bus.on("ping", handler)

    off1.call
    @bus.emit("ping", 9)

    # Only the second registration survives, so the payload lands once.
    assert_equal [9], seen
  end

  def test_a_raising_handler_does_not_stop_the_others
    seen = []
    @bus.on("ping") { raise "boom" }
    @bus.on("ping") { |d| seen << d }

    @bus.emit("ping", 1)

    assert_equal [1], seen
  end

  def test_a_raising_handler_does_not_propagate_to_the_caller
    @bus.on("ping") { raise "boom" }

    @bus.emit("ping", 1) # must not raise
    pass
  end

  def test_a_raising_handler_is_reported_to_the_logger
    logger = CapturingLogger.new
    bus = Truffle::EventBus.new(logger: logger)
    bus.on("ping") { raise "boom" }

    bus.emit("ping", 1)

    assert_equal 1, logger.lines.length
    assert_includes logger.lines.first, "Event handler error (ping)"
    assert_includes logger.lines.first, "boom"
  end

  def test_unsubscribing_during_emit_does_not_disturb_the_current_dispatch
    seen = []
    off = nil
    @bus.on("ping") do
      off.call
      seen << :first
    end
    @bus.on("ping") { seen << :second }
    off = @bus.on("ping") { seen << :third }

    @bus.emit("ping", nil)

    # The snapshot taken at emit time still includes the third handler even
    # though the first handler unsubscribed it mid-dispatch.
    assert_equal %i[first second third], seen
    # On the next emit the unsubscribe has taken effect.
    seen.clear
    @bus.emit("ping", nil)

    assert_equal %i[first second], seen
  end

  def test_subscribing_during_emit_does_not_run_in_the_current_dispatch
    seen = []
    @bus.on("ping") do
      @bus.on("ping") { seen << :added }
      seen << :original
    end

    @bus.emit("ping", nil)

    assert_equal [:original], seen
  end

  def test_clear_drops_every_subscription
    seen = []
    @bus.on("a") { seen << :a }
    @bus.on("b") { seen << :b }

    @bus.clear
    @bus.emit("a", nil)
    @bus.emit("b", nil)

    assert_empty seen
  end

  def test_emit_is_visible_across_threads
    seen = Queue.new
    @bus.on("ping") { |d| seen << d }

    Thread.new { @bus.emit("ping", "threaded") }.join

    assert_equal "threaded", seen.pop
  end

  # Collects the strings the bus would otherwise print to $stderr.
  class CapturingLogger
    attr_reader :lines

    def initialize
      @lines = []
    end

    def puts(line)
      @lines << line
    end
  end
end
