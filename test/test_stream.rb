# frozen_string_literal: true

require "test_helper"

# Drives the OpenAIStream accumulator with hand-built chunk hashes, the same
# shape the SSE transport decodes off the wire. No network: the transport
# (#chat_stream / #stream_post) is exercised separately by the live integration
# test; here we pin the decode logic and the event protocol it emits.
class TestStream < Minitest::Test
  def collect(chunks, finish: true)
    acc = Truffle::Providers::OpenAIStream.new
    events = []
    chunks.each { |chunk| acc.feed(chunk) { |e| events << e } }
    acc.finish { |e| events << e } if finish
    [events, acc]
  end

  def types(events)
    events.map(&:type)
  end

  # A text chunk with the given content delta and optional finish_reason.
  def text_chunk(content, finish_reason: nil)
    delta = {}
    delta["content"] = content unless content.nil?
    { "choices" => [{ "delta" => delta, "finish_reason" => finish_reason }.compact] }
  end

  def test_streams_text_as_start_delta_end_then_done
    events, acc = collect([
                            text_chunk("Hel"),
                            text_chunk("lo"),
                            text_chunk(nil, finish_reason: "stop")
                          ])

    assert_equal %i[start text_start text_delta text_delta text_end done], types(events)

    deltas = events.select { |e| e.type == :text_delta }.map(&:delta)

    assert_equal %w[Hel lo], deltas

    done = events.last

    assert_predicate done, :done?
    assert_equal Truffle::StopReason::STOP, done.reason
    assert_equal "Hello", done.message.text
    assert_equal "Hello", acc.response.message.text
    assert_equal Truffle::StopReason::STOP, acc.response.stop_reason
  end

  def test_text_end_carries_the_full_text
    events, = collect([text_chunk("abc"), text_chunk(nil, finish_reason: "stop")])
    text_end = events.find { |e| e.type == :text_end }

    assert_equal "abc", text_end.content
  end

  def test_streams_thinking_from_reasoning_field
    events, = collect([
                        { "choices" => [{ "delta" => { "reasoning_content" => "think " } }] },
                        { "choices" => [{ "delta" => { "reasoning_content" => "more" } }] },
                        text_chunk(nil, finish_reason: "stop")
                      ])

    assert_equal %i[start thinking_start thinking_delta thinking_delta thinking_end done],
                 types(events)
    thinking_end = events.find { |e| e.type == :thinking_end }

    assert_equal "think more", thinking_end.content
  end

  # pi reads the first non-empty reasoning field so a provider echoing the same
  # text under two keys is not double-counted.
  def test_thinking_prefers_first_nonempty_reasoning_field
    events, = collect([
                        { "choices" => [{ "delta" => { "reasoning_content" => "A",
                                                       "reasoning" => "A" } }] },
                        text_chunk(nil, finish_reason: "stop")
                      ])
    deltas = events.select { |e| e.type == :thinking_delta }.map(&:delta)

    assert_equal %w[A], deltas
  end

  def test_streams_tool_call_assembled_across_chunks
    events, acc = collect([
                            { "choices" => [{ "delta" => { "tool_calls" => [
                              { "index" => 0, "id" => "call_1",
                                "function" => { "name" => "add", "arguments" => "{\"a\":" } }
                            ] } }] },
                            { "choices" => [{ "delta" => { "tool_calls" => [
                              { "index" => 0, "function" => { "arguments" => "1,\"b\":2}" } }
                            ] } }] },
                            text_chunk(nil, finish_reason: "tool_calls")
                          ])

    assert_equal %i[start toolcall_start toolcall_delta toolcall_delta toolcall_end done],
                 types(events)

    toolcall_end = events.find { |e| e.type == :toolcall_end }
    call = toolcall_end.tool_call

    assert_equal "call_1", call.id
    assert_equal "add", call.name
    assert_equal({ "a" => 1, "b" => 2 }, call.arguments)

    assert_equal Truffle::StopReason::TOOL_USE, acc.response.stop_reason
    assert_equal [call], acc.response.message.tool_calls
  end

  def test_two_tool_calls_tracked_by_stream_index
    events, = collect([
                        { "choices" => [{ "delta" => { "tool_calls" => [
                          { "index" => 0, "id" => "a",
                            "function" => { "name" => "one", "arguments" => "{}" } },
                          { "index" => 1, "id" => "b",
                            "function" => { "name" => "two", "arguments" => "{}" } }
                        ] } }] },
                        text_chunk(nil, finish_reason: "tool_calls")
                      ])

    ends = events.select { |e| e.type == :toolcall_end }.map(&:tool_call)

    assert_equal %w[one two], ends.map(&:name)
    assert_equal %w[a b], ends.map(&:id)
  end

  def test_malformed_tool_arguments_surface_under_sentinel_key
    events, = collect([
                        { "choices" => [{ "delta" => { "tool_calls" => [
                          { "index" => 0, "id" => "x",
                            "function" => { "name" => "f", "arguments" => "{not json" } }
                        ] } }] },
                        text_chunk(nil, finish_reason: "tool_calls")
                      ])
    call = events.find { |e| e.type == :toolcall_end }.tool_call

    assert_equal({ "_raw" => "{not json" }, call.arguments)
  end

  def test_failure_finish_reason_yields_error_terminal
    events, acc = collect([text_chunk("partial"), text_chunk(nil, finish_reason: "content_filter")])

    terminal = events.last

    assert_predicate terminal, :error?
    assert_equal Truffle::StopReason::ERROR, terminal.reason
    assert_equal "Provider finish_reason: content_filter", terminal.error_message
    # The text decoded before the failure is still on the final message.
    assert_equal "partial", terminal.message.text
    assert_equal Truffle::StopReason::ERROR, acc.response.stop_reason
  end

  def test_stream_ending_without_finish_reason_is_an_error
    events, acc = collect([text_chunk("hi")])

    terminal = events.last

    assert_predicate terminal, :error?
    assert_equal "Stream ended without finish_reason", terminal.error_message
    assert_equal Truffle::StopReason::ERROR, acc.response.stop_reason
  end

  def test_fail_folds_transport_error_into_stream
    acc = Truffle::Providers::OpenAIStream.new
    events = []
    acc.feed(text_chunk("so far")) { |e| events << e }
    acc.fail(Truffle::Providers::Error.new("connection reset")) { |e| events << e }

    terminal = events.last

    assert_predicate terminal, :error?
    assert_equal Truffle::StopReason::ERROR, terminal.reason
    assert_equal "connection reset", terminal.error_message
    assert_equal "so far", terminal.message.text
    assert_equal Truffle::StopReason::ERROR, acc.response.stop_reason
  end

  def test_abort_folds_into_a_clean_done_terminal_with_partial_content
    acc = Truffle::Providers::OpenAIStream.new
    events = []
    acc.feed(text_chunk("partial ans")) { |e| events << e }
    acc.abort { |e| events << e }

    terminal = events.last
    # An abort is a clean cancellation, not a failure: a :done event, no error.
    assert_predicate terminal, :done?
    assert_equal Truffle::StopReason::ABORTED, terminal.reason
    assert_nil terminal.error_message
    assert_equal "partial ans", terminal.message.text
    assert_equal Truffle::StopReason::ABORTED, acc.response.stop_reason
  end

  def test_abort_seals_open_blocks_before_the_terminal
    acc = Truffle::Providers::OpenAIStream.new
    events = []
    acc.feed(text_chunk("half")) { |e| events << e }
    acc.abort { |e| events << e }

    # The open text block gets its text_end before the done terminal, so a
    # consumer sees a well-formed block sequence even on cancel.
    assert_equal %i[start text_start text_delta text_end done], types(events)
    text_end = events.find { |e| e.type == :text_end }

    assert_equal "half", text_end.content
  end

  def test_abort_with_no_content_still_terminates_cleanly
    acc = Truffle::Providers::OpenAIStream.new
    events = []
    acc.abort { |e| events << e }

    assert_equal %i[start done], types(events)
    assert_equal Truffle::StopReason::ABORTED, events.last.reason
    # No content blocks arrived, so the message has no text (the empty-message
    # contract), and the terminal still carries a real Message.
    assert_nil acc.response.message.text
    assert_empty acc.response.message.content
  end

  def test_usage_captured_from_chunk
    events, acc = collect([
                            text_chunk("hi"),
                            { "choices" => [{ "delta" => {}, "finish_reason" => "stop" }],
                              "usage" => { "prompt_tokens" => 5, "completion_tokens" => 2 } }
                          ])
    usage = acc.response.usage

    assert_equal 5, usage.input
    assert_equal 2, usage.output
    assert_equal 7, usage.total_tokens
    refute_empty events
  end

  def test_usage_priced_from_model_in_chunk
    _events, acc = collect([
                             { "model" => "gpt-4o-mini",
                               "choices" => [{ "delta" => { "content" => "x" } }] },
                             { "choices" => [{ "delta" => {}, "finish_reason" => "stop" }],
                               "usage" => { "prompt_tokens" => 1_000_000,
                                            "completion_tokens" => 1_000_000 } }
                           ])
    cost = acc.response.usage.cost
    # gpt-4o-mini: $0.15/M input, $0.60/M output.
    assert_in_delta 0.15, cost.input, 1e-9
    assert_in_delta 0.6, cost.output, 1e-9
    assert_in_delta 0.75, cost.total, 1e-9
  end

  def test_usage_priced_from_requested_model_when_chunks_omit_it
    acc = Truffle::Providers::OpenAIStream.new(pricing_model: "gpt-4o-mini")
    events = []
    [text_chunk("x"),
     { "choices" => [{ "delta" => {}, "finish_reason" => "stop" }],
       "usage" => { "prompt_tokens" => 1_000_000, "completion_tokens" => 0 } }].each do |c|
      acc.feed(c) { |event| events << event }
    end
    acc.finish { |event| events << event }

    assert_in_delta 0.15, acc.response.usage.cost.total, 1e-9
  end

  def test_model_captured_from_chunk
    _events, acc = collect([
                             { "model" => "gpt-4o-mini-2024",
                               "choices" => [{ "delta" => { "content" => "x" } }] },
                             text_chunk(nil, finish_reason: "stop")
                           ])

    assert_equal "gpt-4o-mini-2024", acc.response.model
  end

  # Every streaming event carries a `partial` snapshot of the message so far.
  # Because the accumulator mutates scratch strings in place, a snapshot must be
  # duped, otherwise a later delta would retroactively change an earlier event.
  def test_partial_snapshots_are_independent_across_deltas
    events, = collect([text_chunk("one"), text_chunk("two"),
                       text_chunk(nil, finish_reason: "stop")])

    first_delta = events.select { |e| e.type == :text_delta }.first

    assert_equal "one", first_delta.partial.text
    # The final message has the full text; the early snapshot is unchanged.
    assert_equal "onetwo", events.last.message.text
  end

  def test_start_event_emitted_once_lazily
    events, = collect([text_chunk("a"), text_chunk(nil, finish_reason: "stop")])

    assert_equal(1, events.count { |e| e.type == :start })
    assert_equal :start, events.first.type
  end

  def test_stream_event_rejects_unknown_type
    assert_raises(ArgumentError) { Truffle::StreamEvent.new(type: :nope) }
  end

  def test_base_chat_stream_is_not_implemented
    base = Truffle::Providers::Base.new
    assert_raises(NotImplementedError) do
      base.chat_stream(messages: [])
    end
  end
end
