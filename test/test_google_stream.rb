# frozen_string_literal: true

require "test_helper"

# Drives the GoogleStream accumulator with hand-built chunk hashes, the same
# shape #stream_post decodes off the streamGenerateContent SSE wire. No network:
# the transport (#chat_stream / #stream_post) is exercised by the live
# integration test; here we pin the decode logic and the event protocol it emits.
class TestGoogleStream < Minitest::Test
  Stream = Truffle::Providers::GoogleStream

  # A base64 string the provider accepts as a thought signature (length % 4 == 0,
  # only base64 characters): "sig" encoded.
  VALID_SIG = "c2ln"

  def collect(frames, finish: true)
    acc = Stream.new(pricing_model: "gemini-2.5-flash")
    events = []
    frames.each { |frame| acc.feed(frame) { |e| events << e } }
    acc.finish { |e| events << e } if finish
    [events, acc]
  end

  def types(events)
    events.map(&:type)
  end

  # --- canonical chunk shapes, as streamGenerateContent sends them ---------

  def text_chunk(text, thought: false, signature: nil)
    part = { "text" => text }
    part["thought"] = true if thought
    part["thoughtSignature"] = signature if signature
    { "candidates" => [{ "content" => { "role" => "model", "parts" => [part] } }] }
  end

  def function_chunk(name, args, id: nil)
    call = { "name" => name, "args" => args }
    call["id"] = id if id
    { "candidates" => [{ "content" => { "role" => "model",
                                        "parts" => [{ "functionCall" => call }] } }] }
  end

  def finish_chunk(reason: "STOP", prompt: 10, candidates: 5, thoughts: 0, cached: 0,
                   model: "gemini-2.5-flash")
    { "candidates" => [{ "finishReason" => reason }],
      "modelVersion" => model,
      "usageMetadata" => {
        "promptTokenCount" => prompt,
        "candidatesTokenCount" => candidates,
        "thoughtsTokenCount" => thoughts,
        "cachedContentTokenCount" => cached,
        "totalTokenCount" => prompt + candidates + thoughts
      } }
  end

  # --- text ----------------------------------------------------------------

  def test_streams_text_as_start_delta_end_then_done
    events, acc = collect([
                            text_chunk("Hel"),
                            text_chunk("lo"),
                            finish_chunk
                          ])

    assert_equal %i[start text_start text_delta text_delta text_end done], types(events)
    assert_equal %w[Hel lo], events.select { |e| e.type == :text_delta }.map(&:delta)
    assert_equal "Hello", events.last.message.text
    assert_equal Truffle::StopReason::STOP, acc.response.stop_reason
    assert_equal "STOP", acc.response.finish_reason
  end

  def test_start_event_is_emitted_exactly_once
    events, = collect([text_chunk("a"), text_chunk("b"), finish_chunk])

    assert_equal(1, events.count { |e| e.type == :start })
  end

  def test_consecutive_text_chunks_stay_in_one_block
    events, = collect([text_chunk("a"), text_chunk("b"), text_chunk("c"), finish_chunk])

    assert_equal(1, events.count { |e| e.type == :text_start })
    assert_equal(1, events.count { |e| e.type == :text_end })
    assert_equal(3, events.count { |e| e.type == :text_delta })
  end

  def test_text_end_carries_the_full_block_text
    events, = collect([text_chunk("Hel"), text_chunk("lo"), finish_chunk])
    text_end = events.find { |e| e.type == :text_end }

    assert_equal "Hello", text_end.content
  end

  # --- thinking ------------------------------------------------------------

  def test_streams_thinking_as_its_own_block
    events, acc = collect([
                            text_chunk("pondering", thought: true, signature: VALID_SIG),
                            text_chunk("answer"),
                            finish_chunk
                          ])

    assert_equal %i[start thinking_start thinking_delta thinking_end
                    text_start text_delta text_end done], types(events)
    thinking = acc.response.message.content.grep(Truffle::Content::Thinking).first

    assert_equal "pondering", thinking.thinking
    assert_equal VALID_SIG, thinking.signature
  end

  def test_kind_flip_closes_the_open_block_before_opening_the_next
    events, = collect([
                        text_chunk("a"),
                        text_chunk("b", thought: true),
                        finish_chunk
                      ])
    # The text block must close before the thinking block opens.
    assert_equal %i[start text_start text_delta text_end
                    thinking_start thinking_delta thinking_end done], types(events)
  end

  def test_thought_signature_keeps_latest_non_empty
    events, acc = collect([
                            text_chunk("a", thought: true, signature: VALID_SIG),
                            text_chunk("b", thought: true, signature: ""),
                            finish_chunk
                          ])
    thinking = acc.response.message.content.grep(Truffle::Content::Thinking).first

    assert_equal VALID_SIG, thinking.signature, "an empty signature must not clobber a real one"
    assert_equal "ab", thinking.thinking
    refute_empty events
  end

  # --- function calls ------------------------------------------------------

  def test_function_call_emits_a_complete_trio
    events, acc = collect([
                            function_chunk("multiply", { "a" => 23, "b" => 19 }),
                            finish_chunk
                          ])

    assert_equal %i[start toolcall_start toolcall_delta toolcall_end done], types(events)
    call = acc.response.message.tool_calls.first

    assert_equal "multiply", call.name
    assert_equal({ "a" => 23, "b" => 19 }, call.arguments)
  end

  def test_function_call_delta_is_the_json_arguments
    events, = collect([function_chunk("f", { "x" => 1 }), finish_chunk])
    delta = events.find { |e| e.type == :toolcall_delta }

    assert_equal({ "x" => 1 }, JSON.parse(delta.delta))
  end

  def test_function_call_closes_an_open_text_block
    events, = collect([
                        text_chunk("thinking out loud"),
                        function_chunk("f", {}),
                        finish_chunk
                      ])

    assert_equal %i[start text_start text_delta text_end
                    toolcall_start toolcall_delta toolcall_end done], types(events)
  end

  def test_tool_use_override_when_finish_is_plain_stop
    _, acc = collect([function_chunk("f", {}), finish_chunk(reason: "STOP")])

    assert_equal Truffle::StopReason::TOOL_USE, acc.response.stop_reason
    assert_nil acc.response.error_message
  end

  def test_missing_call_id_is_synthesized_from_name
    _, acc = collect([function_chunk("multiply", { "a" => 1 }), finish_chunk])

    assert_equal "multiply-0", acc.response.message.tool_calls.first.id
  end

  def test_explicit_call_id_is_kept
    _, acc = collect([function_chunk("f", {}, id: "call_abc"), finish_chunk])

    assert_equal "call_abc", acc.response.message.tool_calls.first.id
  end

  def test_duplicate_call_id_is_replaced
    _, acc = collect([
                       function_chunk("f", {}, id: "dup"),
                       function_chunk("g", {}, id: "dup"),
                       finish_chunk
                     ])
    ids = acc.response.message.tool_calls.map(&:id)

    assert_equal "dup", ids[0]
    assert_equal "g-0", ids[1], "the repeated id must be replaced with a synthesized one"
    assert_equal ids.uniq, ids
  end

  # --- stop reasons --------------------------------------------------------

  def test_max_tokens_is_a_length_stop
    _, acc = collect([text_chunk("partial"), finish_chunk(reason: "MAX_TOKENS")])

    assert_equal Truffle::StopReason::LENGTH, acc.response.stop_reason
  end

  def test_safety_finish_folds_into_an_error_terminal
    events, acc = collect([text_chunk("blocked"), finish_chunk(reason: "SAFETY")])

    assert_equal :error, events.last.type
    assert_equal Truffle::StopReason::ERROR, acc.response.stop_reason
    assert_includes acc.response.error_message, "SAFETY"
  end

  # --- usage + pricing -----------------------------------------------------

  def test_usage_is_taken_from_the_final_usage_metadata
    _, acc = collect([
                       text_chunk("hi"),
                       finish_chunk(prompt: 100, candidates: 40, thoughts: 10, cached: 30)
                     ])
    usage = acc.response.usage

    assert_equal 70, usage.input, "input is the residual after cached tokens"
    assert_equal 50, usage.output, "output is candidates plus thoughts"
    assert_equal 30, usage.cache_read
    assert_equal 10, usage.reasoning
  end

  def test_cost_is_priced_from_the_pricing_model
    _, acc = collect([text_chunk("hi"), finish_chunk(model: nil)])
    # gemini-2.5-flash has non-zero rates, so any non-zero token count costs > 0.
    assert_operator acc.response.usage.cost.total, :>, 0.0
  end

  def test_model_version_from_the_chunk_labels_the_response
    _, acc = collect([text_chunk("hi"), finish_chunk(model: "gemini-2.5-flash-001")])

    assert_equal "gemini-2.5-flash-001", acc.response.model
  end

  # --- partial snapshots ---------------------------------------------------

  def test_non_terminal_events_carry_a_partial_message
    events, = collect([text_chunk("Hel"), text_chunk("lo"), finish_chunk])

    events.reject { |e| %i[done error].include?(e.type) }.each do |event|
      refute_nil event.partial, "#{event.type} should carry a partial snapshot"
    end
  end

  def test_an_early_partial_is_not_mutated_by_later_deltas
    events, = collect([text_chunk("Hel"), text_chunk("lo"), finish_chunk])
    first_delta = events.find { |e| e.type == :text_delta }
    snapshot_text = first_delta.partial.text
    # The very first delta's snapshot saw only "Hel"; a later "lo" must not grow it.
    assert_equal "Hel", snapshot_text
  end

  # --- abort + fail --------------------------------------------------------

  def test_abort_closes_blocks_and_emits_a_clean_done
    acc = Stream.new(pricing_model: "gemini-2.5-flash")
    events = []
    acc.feed(text_chunk("partial")) { |e| events << e }
    acc.abort { |e| events << e }

    assert_equal :done, events.last.type
    assert_equal Truffle::StopReason::ABORTED, acc.response.stop_reason
    assert_nil acc.response.error_message
    assert_equal "partial", events.last.message.text
    # The open text block is sealed on abort.
    assert_equal(1, events.count { |e| e.type == :text_end })
  end

  def test_fail_emits_an_error_with_the_message_so_far
    acc = Stream.new(pricing_model: "gemini-2.5-flash")
    events = []
    acc.feed(text_chunk("half")) { |e| events << e }
    acc.fail(StandardError.new("connection reset")) { |e| events << e }

    assert_equal :error, events.last.type
    assert_equal Truffle::StopReason::ERROR, acc.response.stop_reason
    assert_equal "connection reset", acc.response.error_message
    assert_equal "half", events.last.message.text
  end

  # --- registry wiring -----------------------------------------------------

  def test_provider_exposes_chat_stream
    google = Truffle::Providers::Google.new(api_key: "test-key")

    assert_respond_to google, :chat_stream
  end
end
