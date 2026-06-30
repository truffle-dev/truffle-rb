# frozen_string_literal: true

require "test_helper"
require "stringio"

# Tests for Truffle::CLI.render_print_text: the pure output half of pi's
# print mode. It takes the final assistant Response of a single-shot run and
# writes its text to stdout, or surfaces an error/aborted turn on stderr with a
# nonzero exit, all over injectable streams so it runs offline.
class TestCLIPrint < Minitest::Test
  def render(response)
    out = StringIO.new
    err = StringIO.new
    status = Truffle::CLI.render_print_text(response, out: out, err: err)
    [status, out.string, err.string]
  end

  def assistant(blocks, stop_reason: Truffle::StopReason::STOP, error_message: nil)
    message = Truffle::Message.assistant(content: blocks)
    Truffle::Response.new(message: message, stop_reason: stop_reason, error_message: error_message)
  end

  def test_text_blocks_each_print_on_their_own_line_and_exit_zero
    response = assistant([
                           Truffle::Content::Text.new(text: "first"),
                           Truffle::Content::Text.new(text: "second")
                         ])

    status, out, err = render(response)

    assert_equal 0, status
    assert_equal "first\nsecond\n", out
    assert_empty err
  end

  def test_error_stop_with_message_writes_it_to_stderr_and_exits_one
    response = assistant([Truffle::Content::Text.new(text: "ignored")],
                         stop_reason: Truffle::StopReason::ERROR, error_message: "boom")

    status, out, err = render(response)

    assert_equal 1, status
    assert_equal "boom\n", err
    assert_empty out
  end

  def test_error_stop_without_message_falls_back_to_request_reason
    response = assistant([], stop_reason: Truffle::StopReason::ERROR)

    status, _out, err = render(response)

    assert_equal 1, status
    assert_equal "Request error\n", err
  end

  def test_aborted_stop_without_message_falls_back_to_request_reason
    response = assistant([], stop_reason: Truffle::StopReason::ABORTED)

    status, _out, err = render(response)

    assert_equal 1, status
    assert_equal "Request aborted\n", err
  end

  def test_normal_stop_prints_the_text_even_with_a_set_error_message
    # error_message is only honored on a failure stop reason; a normal stop
    # renders text and ignores it, the way pi only reads errorMessage in the
    # error/aborted branch.
    response = assistant([Truffle::Content::Text.new(text: "answer")],
                         stop_reason: Truffle::StopReason::STOP, error_message: "stale")

    status, out, err = render(response)

    assert_equal 0, status
    assert_equal "answer\n", out
    assert_empty err
  end

  def test_only_text_blocks_are_printed_thinking_and_tool_calls_are_skipped
    response = assistant([
                           Truffle::Content::Thinking.new(thinking: "reasoning"),
                           Truffle::Content::Text.new(text: "visible"),
                           Truffle::ToolCall.new(id: "1", name: "noop", arguments: {})
                         ])

    status, out, err = render(response)

    assert_equal 0, status
    assert_equal "visible\n", out
    assert_empty err
  end

  def test_a_turn_with_no_text_blocks_prints_nothing_and_exits_zero
    response = assistant([Truffle::ToolCall.new(id: "1", name: "noop", arguments: {})])

    status, out, err = render(response)

    assert_equal 0, status
    assert_empty out
    assert_empty err
  end

  def test_nil_response_prints_nothing_and_exits_zero
    status, out, err = render(nil)

    assert_equal 0, status
    assert_empty out
    assert_empty err
  end

  def test_a_text_block_ending_in_a_newline_keeps_its_own_plus_the_separator
    # pi appends `\n` to every text block unconditionally (writeRawStdout), so a
    # block that already ends in a newline yields two. Using IO#write rather than
    # IO#puts is what preserves that byte-for-byte.
    response = assistant([Truffle::Content::Text.new(text: "trailing\n")])

    status, out, = render(response)

    assert_equal 0, status
    assert_equal "trailing\n\n", out
  end

  def test_json_event_renderer_serializes_truffle_values
    out = StringIO.new
    call = Truffle::ToolCall.new(id: "c1", name: "lookup", arguments: { "city" => nil })
    message = Truffle::Message.assistant(content: [call])
    usage = Truffle::Usage.new(input: 3, output: 5, cache_read: 2, reasoning: 1)

    status = Truffle::CLI.render_print_json(
      :message,
      { message: message, usage: usage, stop_reason: :tool_use, error_message: nil },
      out: out
    )
    event = JSON.parse(out.string)

    assert_equal 0, status
    assert_equal "message", event["type"]
    assert_equal "assistant", event["message"]["role"]
    assert_equal "tool_call", event["message"]["content"].first["type"]
    assert_equal({ "city" => nil }, event["message"]["content"].first["arguments"])
    assert_equal 3, event["usage"]["input"]
    assert_equal 1, event["usage"]["reasoning"]
    assert_equal "tool_use", event["stop_reason"]
    refute_includes event, "error_message"
  end
end
