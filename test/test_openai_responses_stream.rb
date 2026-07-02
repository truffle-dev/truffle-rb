# frozen_string_literal: true

require "test_helper"

# Drives the OpenAIResponsesStream accumulator with hand-built event hashes, the
# same shape #stream_post decodes off the Responses SSE wire. No network: the
# transport (#chat_stream / #stream_post) is exercised by the live integration
# test; here we pin the decode logic and the event protocol it emits.
class TestOpenAIResponsesStream < Minitest::Test
  Stream = Truffle::Providers::OpenAIResponsesStream
  Items = Truffle::Providers::OpenAIResponsesShared

  def collect(frames, finish: true)
    acc = Stream.new(pricing_model: "gpt-5.5")
    events = []
    frames.each { |frame| acc.feed(frame) { |e| events << e } }
    acc.finish { |e| events << e } if finish
    [events, acc]
  end

  def types(events)
    events.map(&:type)
  end

  # --- the canonical event shapes, as the API sends them -------------------

  def created
    { "type" => "response.created",
      "response" => { "id" => "resp_1", "model" => "gpt-5.5", "status" => "in_progress" } }
  end

  def item_added(index, item)
    { "type" => "response.output_item.added", "output_index" => index, "item" => item }
  end

  def item_done(index, item)
    { "type" => "response.output_item.done", "output_index" => index, "item" => item }
  end

  def text_delta(index, text)
    { "type" => "response.output_text.delta", "output_index" => index,
      "item_id" => "msg_1", "content_index" => 0, "delta" => text }
  end

  def message_item(text, id: "msg_1", phase: nil)
    item = { "type" => "message", "id" => id, "role" => "assistant",
             "status" => "completed",
             "content" => [{ "type" => "output_text", "text" => text, "annotations" => [] }] }
    item["phase"] = phase if phase
    item
  end

  def reasoning_item(summaries, encrypted: "enc-xyz", id: "rs_1")
    { "type" => "reasoning", "id" => id,
      "summary" => summaries.map { |text| { "type" => "summary_text", "text" => text } },
      "encrypted_content" => encrypted }
  end

  def function_call_item(args, call_id: "call_1", name: "add", id: "fc_1")
    { "type" => "function_call", "id" => id, "call_id" => call_id,
      "name" => name, "arguments" => args }
  end

  def completed(usage: { "input_tokens" => 10, "output_tokens" => 5 }, status: "completed")
    { "type" => "response.completed",
      "response" => { "id" => "resp_1", "status" => status, "usage" => usage } }
  end

  # --- text -----------------------------------------------------------------

  def test_streams_text_as_start_delta_end_then_done
    events, acc = collect([
                            created,
                            item_added(0, message_item("")),
                            text_delta(0, "Hel"),
                            text_delta(0, "lo"),
                            item_done(0, message_item("Hello")),
                            completed
                          ])

    assert_equal %i[start text_start text_delta text_delta text_end done], types(events)
    assert_equal %w[Hel lo], events.select { |e| e.type == :text_delta }.map(&:delta)

    done = events.last

    assert_predicate done, :done?
    assert_equal Truffle::StopReason::STOP, done.reason
    assert_equal "Hello", done.message.text
    assert_equal "Hello", acc.response.message.text
    assert_equal "gpt-5.5", acc.response.model
  end

  def test_text_block_signature_carries_the_item_id_and_phase
    _events, acc = collect([
                             created,
                             item_added(0, message_item("")),
                             text_delta(0, "On it."),
                             item_done(0, message_item("On it.", phase: "commentary")),
                             completed
                           ])
    block = acc.response.message.content.first

    assert_equal({ id: "msg_1", phase: "commentary" },
                 Items.parse_text_signature(block.signature))
  end

  # --- reasoning summaries ----------------------------------------------------

  def summary_delta(index, text)
    { "type" => "response.reasoning_summary_text.delta", "output_index" => index,
      "item_id" => "rs_1", "summary_index" => 0, "delta" => text }
  end

  def summary_part_done(index)
    { "type" => "response.reasoning_summary_part.done", "output_index" => index,
      "item_id" => "rs_1", "summary_index" => 0,
      "part" => { "type" => "summary_text", "text" => "step one" } }
  end

  def test_reasoning_summary_streams_as_thinking_events
    events, acc = collect([
                            created,
                            item_added(0, { "type" => "reasoning", "id" => "rs_1",
                                            "summary" => [] }),
                            summary_delta(0, "step "),
                            summary_delta(0, "one"),
                            summary_part_done(0),
                            item_done(0, reasoning_item(["step one"])),
                            completed
                          ])

    assert_equal %i[start thinking_start thinking_delta thinking_delta thinking_delta
                    thinking_end done],
                 types(events)
    # The part separator arrives as one more thinking delta...
    assert_equal ["step ", "one", "\n\n"],
                 events.select { |e| e.type == :thinking_delta }.map(&:delta)
    # ...but the sealed block carries the item's authoritative summary text.
    thinking = acc.response.message.content.first

    assert_equal "step one", thinking.thinking
  end

  def test_reasoning_signature_preserves_the_item_with_encrypted_content
    _events, acc = collect([
                             created,
                             item_added(0, { "type" => "reasoning", "id" => "rs_1",
                                             "summary" => [] }),
                             summary_delta(0, "step one"),
                             item_done(0, reasoning_item(["step one"])),
                             completed
                           ])
    thinking = acc.response.message.content.first
    item = JSON.parse(thinking.signature)

    assert_equal "reasoning", item["type"]
    assert_equal "rs_1", item["id"]
    assert_equal "enc-xyz", item["encrypted_content"]
    # The replay path accepts the block it just produced.
    assert_equal item, Items.reasoning_item(thinking)
  end

  def test_multiple_summary_parts_join_with_blank_lines
    _events, acc = collect([
                             created,
                             item_added(0, { "type" => "reasoning", "id" => "rs_1",
                                             "summary" => [] }),
                             item_done(0, reasoning_item(%w[one two])),
                             completed
                           ])

    assert_equal "one\n\ntwo", acc.response.message.content.first.thinking
  end

  def test_reasoning_text_delta_also_drives_the_thinking_block
    frames = [
      created,
      item_added(0, { "type" => "reasoning", "id" => "rs_1", "summary" => [] }),
      { "type" => "response.reasoning_text.delta", "output_index" => 0,
        "item_id" => "rs_1", "content_index" => 0, "delta" => "raw thought" }
    ]
    events, = collect(frames, finish: false)

    assert_equal "raw thought", events.find { |e| e.type == :thinking_delta }.delta
  end

  # --- tool calls ---------------------------------------------------------------

  def args_delta(index, piece)
    { "type" => "response.function_call_arguments.delta", "output_index" => index,
      "item_id" => "fc_1", "delta" => piece }
  end

  def args_done(index, args)
    { "type" => "response.function_call_arguments.done", "output_index" => index,
      "item_id" => "fc_1", "name" => "add", "arguments" => args }
  end

  def test_streams_tool_call_assembled_from_argument_deltas
    events, acc = collect([
                            created,
                            item_added(0, function_call_item("")),
                            args_delta(0, '{"a":1,'),
                            args_delta(0, '"b":2}'),
                            args_done(0, '{"a":1,"b":2}'),
                            item_done(0, function_call_item('{"a":1,"b":2}')),
                            completed
                          ])

    assert_equal %i[start toolcall_start toolcall_delta toolcall_delta toolcall_end done],
                 types(events)

    call = acc.response.message.tool_calls.first

    assert_equal "call_1", call.id
    assert_equal "add", call.name
    assert_equal({ "a" => 1, "b" => 2 }, call.arguments)
  end

  def test_completed_turn_with_tool_calls_upgrades_to_tool_use
    # The Responses API has no tool_calls status; a tool-requesting turn still
    # completes as "completed", so the accumulator upgrades the stop reason.
    events, acc = collect([
                            created,
                            item_added(0, function_call_item("")),
                            args_done(0, "{}"),
                            item_done(0, function_call_item("{}")),
                            completed
                          ])

    assert_equal Truffle::StopReason::TOOL_USE, events.last.reason
    assert_equal Truffle::StopReason::TOOL_USE, acc.response.stop_reason
  end

  def test_arguments_done_emits_the_remainder_when_it_extends_the_buffer
    events, = collect([
                        created,
                        item_added(0, function_call_item("")),
                        args_delta(0, '{"a":'),
                        args_done(0, '{"a":1}'),
                        item_done(0, function_call_item('{"a":1}')),
                        completed
                      ])
    deltas = events.select { |e| e.type == :toolcall_delta }.map(&:delta)

    assert_equal ['{"a":', "1}"], deltas
  end

  def test_item_done_without_added_still_emits_a_full_block
    # A function_call whose arguments never streamed as deltas arrives whole at
    # output_item.done; the block opens and seals in one step.
    events, acc = collect([
                            created,
                            item_done(0, function_call_item('{"a":1}')),
                            completed
                          ])

    assert_equal %i[start toolcall_start toolcall_end done], types(events)
    assert_equal({ "a" => 1 }, acc.response.message.tool_calls.first.arguments)
  end

  def test_toolcall_delta_snapshot_parses_partial_arguments
    frames = [
      created,
      item_added(0, function_call_item("")),
      args_delta(0, '{"a":1,')
    ]
    events, = collect(frames, finish: false)
    call = events.find { |e| e.type == :toolcall_delta }.partial.tool_calls.first

    assert_equal({ "a" => 1 }, call.arguments)
  end

  # --- refusals and unknown items -----------------------------------------------

  def test_refusal_delta_reads_as_text
    frames = [
      created,
      item_added(0, message_item("")),
      { "type" => "response.refusal.delta", "output_index" => 0,
        "item_id" => "msg_1", "content_index" => 0, "delta" => "cannot help" }
    ]
    events, = collect(frames, finish: false)

    assert_equal "cannot help", events.find { |e| e.type == :text_delta }.delta
  end

  def test_unknown_item_types_are_ignored
    events, acc = collect([
                            created,
                            item_added(0, { "type" => "web_search_call", "id" => "ws_1" }),
                            item_done(0, { "type" => "web_search_call", "id" => "ws_1" }),
                            item_added(1, message_item("")),
                            text_delta(1, "hi"),
                            item_done(1, message_item("hi")),
                            completed
                          ])

    assert_equal %i[start text_start text_delta text_end done], types(events)
    assert_equal "hi", acc.response.message.text
  end

  # --- partial snapshots -----------------------------------------------------------

  def test_partial_snapshot_is_not_mutated_by_later_deltas
    captured = nil
    acc = Stream.new
    [created, item_added(0, message_item("")), text_delta(0, "one")].each do |frame|
      acc.feed(frame) { |e| captured = e.partial if e.type == :text_delta }
    end
    acc.feed(text_delta(0, "-two"))

    assert_equal "one", captured.text
  end

  # --- terminals -----------------------------------------------------------------

  def test_incomplete_maps_to_length
    frames = [
      created,
      item_added(0, message_item("")),
      text_delta(0, "trunc"),
      item_done(0, message_item("trunc")),
      { "type" => "response.incomplete",
        "response" => { "id" => "resp_1", "status" => "incomplete",
                        "incomplete_details" => { "reason" => "max_output_tokens" },
                        "usage" => { "input_tokens" => 1, "output_tokens" => 1 } } }
    ]
    events, acc = collect(frames)

    assert_equal Truffle::StopReason::LENGTH, events.last.reason
    assert_equal "trunc", acc.response.message.text
  end

  def test_failed_response_is_a_terminal_error_with_the_response_error
    frames = [
      created,
      { "type" => "response.failed",
        "response" => { "id" => "resp_1", "status" => "failed",
                        "error" => { "code" => "server_error", "message" => "boom" } } }
    ]
    events, acc = collect(frames)

    assert_predicate events.last, :error?
    assert_equal "server_error: boom", acc.response.error_message
  end

  def test_mid_stream_error_event_folds_into_a_terminal_error
    events, acc = collect([created, { "type" => "error", "code" => "rate_limit_exceeded",
                                      "message" => "slow down" }])

    assert_predicate events.last, :error?
    assert_equal "rate_limit_exceeded: slow down", acc.response.error_message
  end

  def test_stream_that_ends_before_a_terminal_event_is_an_error
    events, acc = collect([created, item_added(0, message_item("")), text_delta(0, "x")])

    assert_predicate events.last, :error?
    assert_equal "Stream ended before response.completed", acc.response.error_message
  end

  # --- usage + cost ------------------------------------------------------------------

  def test_usage_maps_cached_and_reasoning_tokens
    usage_payload = {
      "input_tokens" => 100, "output_tokens" => 20,
      "input_tokens_details" => { "cached_tokens" => 40 },
      "output_tokens_details" => { "reasoning_tokens" => 7 },
      "total_tokens" => 120
    }
    _events, acc = collect([
                             created,
                             item_added(0, message_item("")),
                             text_delta(0, "hi"),
                             item_done(0, message_item("hi")),
                             completed(usage: usage_payload)
                           ])
    usage = acc.response.usage

    assert_equal 60, usage.input
    assert_equal 40, usage.cache_read
    assert_equal 20, usage.output
    assert_equal 7, usage.reasoning
    assert_operator usage.cost.total, :>, 0.0
  end

  # --- abort ---------------------------------------------------------------------------

  def test_abort_mid_text_seals_the_block_and_ends_clean
    acc = Stream.new
    events = []
    [created, item_added(0, message_item("")), text_delta(0, "par")].each do |frame|
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
