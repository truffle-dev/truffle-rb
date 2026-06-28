# frozen_string_literal: true

require "test_helper"

class TestStopReason < Minitest::Test
  # The canonical set mirrors pi's StopReason union, spelled in Ruby symbols.
  def test_canonical_set
    assert_equal %i[stop length tool_use error aborted], Truffle::StopReason::ALL
    assert Truffle::StopReason.valid?(:tool_use)
    refute Truffle::StopReason.valid?(:toolUse)
    refute Truffle::StopReason.valid?(:done)
  end

  # The finish_reason -> StopReason mapping, a faithful port of pi's mapStopReason.
  def test_maps_clean_stops
    map = Truffle::Providers::OpenAI.method(:map_stop_reason)

    assert_equal [:stop, nil], map.call(nil)
    assert_equal [:stop, nil], map.call("stop")
    assert_equal [:stop, nil], map.call("end")
  end

  def test_maps_length
    assert_equal [:length, nil], Truffle::Providers::OpenAI.map_stop_reason("length")
  end

  def test_maps_tool_use_for_both_spellings
    assert_equal [:tool_use, nil], Truffle::Providers::OpenAI.map_stop_reason("tool_calls")
    assert_equal [:tool_use, nil], Truffle::Providers::OpenAI.map_stop_reason("function_call")
  end

  def test_maps_known_failures_with_message
    reason, message = Truffle::Providers::OpenAI.map_stop_reason("content_filter")

    assert_equal :error, reason
    assert_equal "Provider finish_reason: content_filter", message

    reason, message = Truffle::Providers::OpenAI.map_stop_reason("network_error")

    assert_equal :error, reason
    assert_equal "Provider finish_reason: network_error", message
  end

  def test_maps_unknown_reason_to_error_carrying_the_raw_reason
    reason, message = Truffle::Providers::OpenAI.map_stop_reason("something_new")

    assert_equal :error, reason
    assert_equal "Provider finish_reason: something_new", message
  end

  def test_response_carries_stop_reason_and_error_message
    response = Truffle::Response.new(
      message: Truffle::Message.assistant(content: "hi"),
      finish_reason: "content_filter",
      stop_reason: :error,
      error_message: "Provider finish_reason: content_filter"
    )

    assert_equal :error, response.stop_reason
    assert_equal "Provider finish_reason: content_filter", response.error_message
    assert_equal "content_filter", response.finish_reason
  end

  def test_response_stop_reason_defaults_to_nil
    response = Truffle::Response.new(message: Truffle::Message.assistant(content: "hi"))

    assert_nil response.stop_reason
    assert_nil response.error_message
  end
end
