# frozen_string_literal: true

require "test_helper"

# Drives the AnthropicStream accumulator with hand-built event hashes, the same
# shape #stream_post decodes off the Messages SSE wire. No network: the transport
# (#chat_stream / #stream_post) is exercised by the live integration test; here
# we pin the decode logic and the event protocol it emits.
class TestAnthropicStream < Minitest::Test
  Stream = Truffle::Providers::AnthropicStream

  def collect(frames, finish: true)
    acc = Stream.new(pricing_model: "claude-sonnet-4-5")
    events = []
    frames.each { |frame| acc.feed(frame) { |e| events << e } }
    acc.finish { |e| events << e } if finish
    [events, acc]
  end

  def types(events)
    events.map(&:type)
  end

  # --- the canonical event shapes, as the API sends them -----------------

  def message_start(input: 10, output: 1)
    { "type" => "message_start",
      "message" => { "id" => "msg_1", "model" => "claude-sonnet-4-5",
                     "usage" => { "input_tokens" => input, "output_tokens" => output } } }
  end

  def text_block_start(index)
    { "type" => "content_block_start", "index" => index,
      "content_block" => { "type" => "text", "text" => "" } }
  end

  def text_delta(index, text)
    { "type" => "content_block_delta", "index" => index,
      "delta" => { "type" => "text_delta", "text" => text } }
  end

  def block_stop(index)
    { "type" => "content_block_stop", "index" => index }
  end

  def message_delta(stop_reason:, output: 5)
    { "type" => "message_delta",
      "delta" => { "stop_reason" => stop_reason },
      "usage" => { "output_tokens" => output } }
  end

  def message_stop
    { "type" => "message_stop" }
  end

  # --- text ---------------------------------------------------------------

  def test_streams_text_as_start_delta_end_then_done
    events, acc = collect([
                            message_start,
                            text_block_start(0),
                            text_delta(0, "Hel"),
                            text_delta(0, "lo"),
                            block_stop(0),
                            message_delta(stop_reason: "end_turn"),
                            message_stop
                          ])

    assert_equal %i[start text_start text_delta text_delta text_end done], types(events)
    assert_equal %w[Hel lo], events.select { |e| e.type == :text_delta }.map(&:delta)

    done = events.last

    assert_predicate done, :done?
    assert_equal Truffle::StopReason::STOP, done.reason
    assert_equal "Hello", done.message.text
    assert_equal "Hello", acc.response.message.text
    assert_equal Truffle::StopReason::STOP, acc.response.stop_reason
  end

  def test_text_end_carries_the_full_text
    events, = collect([message_start, text_block_start(0), text_delta(0, "abc"),
                       block_stop(0), message_delta(stop_reason: "end_turn"), message_stop])
    text_end = events.find { |e| e.type == :text_end }

    assert_equal "abc", text_end.content
  end

  # --- partial snapshots --------------------------------------------------

  def test_partial_snapshot_is_not_mutated_by_later_deltas
    captured = nil
    acc = Stream.new
    [message_start, text_block_start(0), text_delta(0, "one")].each do |frame|
      acc.feed(frame) { |e| captured = e.partial if e.type == :text_delta }
    end
    acc.feed(text_delta(0, "-two"))

    # The snapshot taken at the first delta still reads "one", proving the
    # accumulator dups its scratch string rather than aliasing it.
    assert_equal "one", captured.text
  end

  # --- thinking -----------------------------------------------------------

  def test_streams_thinking_with_signature
    frames = [
      message_start,
      { "type" => "content_block_start", "index" => 0,
        "content_block" => { "type" => "thinking", "thinking" => "" } },
      { "type" => "content_block_delta", "index" => 0,
        "delta" => { "type" => "thinking_delta", "thinking" => "step " } },
      { "type" => "content_block_delta", "index" => 0,
        "delta" => { "type" => "signature_delta", "signature" => "sig-abc" } },
      block_stop(0),
      message_delta(stop_reason: "end_turn"),
      message_stop
    ]
    events, acc = collect(frames)

    assert_equal %i[start thinking_start thinking_delta thinking_end done], types(events)
    thinking = acc.response.message.content.first

    assert_equal "step ", thinking.thinking
    assert_equal "sig-abc", thinking.signature
  end

  def test_redacted_thinking_block_carries_its_data_as_signature
    frames = [
      message_start,
      { "type" => "content_block_start", "index" => 0,
        "content_block" => { "type" => "redacted_thinking", "data" => "enc-xyz" } },
      block_stop(0),
      message_delta(stop_reason: "end_turn"),
      message_stop
    ]
    _events, acc = collect(frames)
    block = acc.response.message.content.first

    assert_predicate block, :redacted?
    assert_equal "enc-xyz", block.signature
  end

  # --- tool use -----------------------------------------------------------

  def test_streams_tool_use_assembled_from_input_json_deltas
    frames = [
      message_start,
      { "type" => "content_block_start", "index" => 0,
        "content_block" => {
          "type" => "tool_use", "id" => "toolu_1", "name" => "add", "input" => {}
        } },
      { "type" => "content_block_delta", "index" => 0,
        "delta" => { "type" => "input_json_delta", "partial_json" => '{"a":1,' } },
      { "type" => "content_block_delta", "index" => 0,
        "delta" => { "type" => "input_json_delta", "partial_json" => '"b":2}' } },
      block_stop(0),
      message_delta(stop_reason: "tool_use"),
      message_stop
    ]
    events, acc = collect(frames)

    assert_equal %i[start toolcall_start toolcall_delta toolcall_delta toolcall_end done],
                 types(events)

    done = events.last

    assert_equal Truffle::StopReason::TOOL_USE, done.reason

    call = acc.response.message.tool_calls.first

    assert_equal "toolu_1", call.id
    assert_equal "add", call.name
    assert_equal({ "a" => 1, "b" => 2 }, call.arguments)
  end

  def test_toolcall_end_carries_parsed_arguments
    frames = [
      message_start,
      { "type" => "content_block_start", "index" => 0,
        "content_block" => { "type" => "tool_use", "id" => "t", "name" => "noop", "input" => {} } },
      { "type" => "content_block_delta", "index" => 0,
        "delta" => { "type" => "input_json_delta", "partial_json" => "{}" } },
      block_stop(0),
      message_delta(stop_reason: "tool_use"),
      message_stop
    ]
    events, = collect(frames)
    toolcall_end = events.find { |e| e.type == :toolcall_end }

    assert_equal({}, toolcall_end.tool_call.arguments)
  end

  # --- stop reasons -------------------------------------------------------

  def test_max_tokens_maps_to_length_stop_reason
    events, acc = collect([message_start, text_block_start(0), text_delta(0, "x"),
                           block_stop(0), message_delta(stop_reason: "max_tokens"), message_stop])

    assert_equal Truffle::StopReason::LENGTH, events.last.reason
    assert_equal Truffle::StopReason::LENGTH, acc.response.stop_reason
  end

  def test_refusal_is_a_terminal_error_with_the_explanation
    frames = [
      message_start,
      { "type" => "message_delta",
        "delta" => { "stop_reason" => "refusal",
                     "stop_details" => { "explanation" => "no" } },
        "usage" => { "output_tokens" => 0 } },
      message_stop
    ]
    events, acc = collect(frames)
    terminal = events.last

    assert_predicate terminal, :error?
    assert_equal Truffle::StopReason::ERROR, terminal.reason
    assert_equal "no", terminal.error_message
    assert_equal "no", acc.response.error_message
  end

  def test_mid_stream_error_event_folds_into_a_terminal_error
    frames = [
      message_start,
      { "type" => "error", "error" => { "type" => "overloaded_error", "message" => "overloaded" } }
    ]
    events, acc = collect(frames)

    assert_predicate events.last, :error?
    assert_equal "overloaded", acc.response.error_message
  end

  def test_stream_that_ends_before_a_stop_reason_is_an_error
    events, acc = collect([message_start, text_block_start(0), text_delta(0, "x"), block_stop(0)])

    assert_predicate events.last, :error?
    assert_equal "Stream ended before message_stop", acc.response.error_message
  end

  # --- usage + cost -------------------------------------------------------

  def test_usage_accumulates_input_from_start_and_output_from_delta
    _events, acc = collect([
                             message_start(input: 42, output: 0),
                             text_block_start(0), text_delta(0, "hi"), block_stop(0),
                             message_delta(stop_reason: "end_turn", output: 7),
                             message_stop
                           ])
    usage = acc.response.usage

    # input survives from message_start even though message_delta omits it; the
    # final output_tokens from message_delta wins over the start value.
    assert_equal 42, usage.input
    assert_equal 7, usage.output
    assert_operator usage.cost.total, :>, 0.0
  end

  # --- abort --------------------------------------------------------------

  def test_abort_mid_text_seals_the_block_and_ends_clean
    acc = Stream.new
    events = []
    [message_start, text_block_start(0), text_delta(0, "par")].each do |frame|
      acc.feed(frame) { |e| events << e }
    end
    acc.abort { |e| events << e }

    assert_equal %i[start text_start text_delta text_end done], types(events)

    done = events.last

    assert_predicate done, :done?
    assert_equal Truffle::StopReason::ABORTED, done.reason
    assert_equal "par", acc.response.message.text
    assert_nil acc.response.error_message
  end

  def test_pre_aborted_signal_yields_an_empty_aborted_turn
    acc = Stream.new
    events = []
    acc.abort { |e| events << e }

    assert_equal %i[start done], types(events)
    assert_equal Truffle::StopReason::ABORTED, acc.response.stop_reason
  end
end
