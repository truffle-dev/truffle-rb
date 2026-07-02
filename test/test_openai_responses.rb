# frozen_string_literal: true

require "test_helper"

# Pins the OpenAI Responses provider's pure wire transforms: building the
# request body (stateless store/include, reasoning config, typed input items,
# tool schema, text.format), deserializing an output array, the reasoning and
# message signature round-trips, mapping statuses, and parsing usage. These are
# class methods fed hand-built data, so the whole suite runs offline with no
# api_key and no network; the live round-trip is in
# test_openai_responses_integration.rb.
class TestOpenAIResponses < Minitest::Test
  Responses = Truffle::Providers::OpenAIResponses
  Items = Truffle::Providers::OpenAIResponsesShared

  def add_tool
    Truffle::Tool.define("add", "Add two integers") do
      param :a, :integer, "first addend", required: true
      param :b, :integer, "second addend", required: true
      run { |a:, b:| a + b }
    end
  end

  def build(messages, tools: [], options: {})
    Responses.build_body(messages, tools, "gpt-5.5", options)
  end

  # --- build_body: the stateless envelope ---------------------------------

  def test_body_is_stateless_with_encrypted_reasoning_included
    body = build([Truffle::Message.user("hi")])

    assert_equal "gpt-5.5", body[:model]
    refute body[:store]
    assert_equal ["reasoning.encrypted_content"], body[:include]
  end

  def test_reasoning_config_passes_through_with_summary_defaulted
    body = build([Truffle::Message.user("hi")],
                 options: { reasoning: { effort: "high" } })

    assert_equal({ effort: "high", summary: "auto" }, body[:reasoning])
  end

  def test_explicit_reasoning_summary_is_preserved
    body = build([Truffle::Message.user("hi")],
                 options: { reasoning: { effort: "low", summary: "detailed" } })

    assert_equal({ effort: "low", summary: "detailed" }, body[:reasoning])
  end

  def test_no_reasoning_config_omits_the_field
    body = build([Truffle::Message.user("hi")])

    refute body.key?(:reasoning)
  end

  def test_max_tokens_maps_to_max_output_tokens
    body = build([Truffle::Message.user("hi")], options: { max_tokens: 512 })

    assert_equal 512, body[:max_output_tokens]
  end

  def test_temperature_passes_through_when_given
    body = build([Truffle::Message.user("hi")], options: { temperature: 0.2 })

    assert_in_delta 0.2, body[:temperature], 1e-9
    refute build([Truffle::Message.user("hi")]).key?(:temperature)
  end

  # --- build_body: tools ---------------------------------------------------

  def test_tools_convert_to_flat_function_schema
    body = build([Truffle::Message.user("hi")], tools: [add_tool.to_schema])
    tool = body[:tools].first

    assert_equal "function", tool[:type]
    assert_equal "add", tool[:name]
    assert_equal "Add two integers", tool[:description]
    assert_equal %w[a b], tool[:parameters][:required]
    refute tool[:strict]
    # Responses tools are flat: no Chat Completions "function" wrapper.
    refute tool.key?(:function)
  end

  def test_no_tools_omits_tools_and_tool_choice
    body = build([Truffle::Message.user("hi")])

    refute body.key?(:tools)
    refute body.key?(:tool_choice)
  end

  # --- convert_messages: input items ---------------------------------------

  def test_system_message_stays_a_system_role_item
    body = build([Truffle::Message.system("Be precise."), Truffle::Message.user("hi")])

    assert_equal({ role: "system", content: "Be precise." }, body[:input].first)
  end

  def test_text_only_user_message_is_a_plain_string
    body = build([Truffle::Message.user("what is 2+2?")])

    assert_equal({ role: "user", content: "what is 2+2?" }, body[:input].first)
  end

  def test_user_content_with_image_becomes_input_parts
    image = Truffle::Content::Image.new(data: "base64data", mime_type: "image/png")
    msg = Truffle::Message.user([Truffle::Content::Text.new(text: "look"), image])
    content = build([msg])[:input].first[:content]

    assert_equal({ type: "input_text", text: "look" }, content.first)
    img = content.last

    assert_equal "input_image", img[:type]
    assert_equal "data:image/png;base64,base64data", img[:image_url]
  end

  def test_tool_call_becomes_a_function_call_item_without_item_id
    assistant = Truffle::Message.assistant(
      tool_calls: [Truffle::ToolCall.new(id: "call_1", name: "add",
                                         arguments: { "a" => 2, "b" => 3 })]
    )
    item = build([assistant])[:input].first

    assert_equal "function_call", item[:type]
    assert_equal "call_1", item[:call_id]
    assert_equal "add", item[:name]
    assert_equal '{"a":2,"b":3}', item[:arguments]
    # Omitting the fc_... item id sidesteps OpenAI's reasoning-pairing
    # validation, the way pi's cross-model path does.
    refute item.key?(:id)
  end

  def test_tool_result_becomes_a_function_call_output
    msg = Truffle::Message.tool(content: "5", tool_call_id: "call_1", name: "add")
    item = build([msg])[:input].first

    assert_equal({ type: "function_call_output", call_id: "call_1", output: "5" }, item)
  end

  def test_tool_result_with_image_becomes_part_list_output
    image = Truffle::Content::Image.new(data: "d", mime_type: "image/jpeg")
    msg = Truffle::Message.tool(content: [Truffle::Content::Text.new(text: "shot"), image],
                                tool_call_id: "c1")
    output = build([msg])[:input].first[:output]

    part_types = output.map { |part| part[:type] }

    assert_equal %w[input_text input_image], part_types
    assert_equal "data:image/jpeg;base64,d", output.last[:image_url]
  end

  # --- assistant round-trip: reasoning items --------------------------------

  def reasoning_signature
    JSON.generate(
      "type" => "reasoning", "id" => "rs_1",
      "summary" => [{ "type" => "summary_text", "text" => "pondered" }],
      "encrypted_content" => "enc-xyz"
    )
  end

  def test_signed_thinking_block_replays_its_reasoning_item_verbatim
    msg = Truffle::Message.assistant(
      content: [Truffle::Content::Thinking.new(thinking: "pondered",
                                               signature: reasoning_signature)]
    )
    item = build([msg])[:input].first

    assert_equal "reasoning", item["type"]
    assert_equal "rs_1", item["id"]
    assert_equal "enc-xyz", item["encrypted_content"]
  end

  def test_unsigned_thinking_block_is_dropped_from_replay
    msg = Truffle::Message.assistant(
      content: [Truffle::Content::Thinking.new(thinking: "pondered")]
    )

    assert_empty build([msg])[:input]
  end

  def test_foreign_thinking_signature_is_dropped_from_replay
    # An Anthropic signature is opaque base64, not a reasoning item; replaying
    # it would 400, so the block is skipped.
    msg = Truffle::Message.assistant(
      content: [Truffle::Content::Thinking.new(thinking: "pondered", signature: "sig-abc")]
    )

    assert_empty build([msg])[:input]
  end

  # --- assistant round-trip: message items -----------------------------------

  def test_text_block_with_signature_keeps_its_id_and_phase
    signature = Items.encode_text_signature("msg_abc", "commentary")
    msg = Truffle::Message.assistant(
      content: [Truffle::Content::Text.new(text: "On it.", signature: signature)]
    )
    item = build([msg])[:input].first

    assert_equal "message", item[:type]
    assert_equal "msg_abc", item[:id]
    assert_equal "commentary", item[:phase]
    assert_equal [{ type: "output_text", text: "On it.", annotations: [] }], item[:content]
  end

  def test_text_block_without_signature_gets_a_fresh_message_id
    msg = Truffle::Message.assistant(content: "Hello.")
    item = build([Truffle::Message.user("hi"), msg])[:input].last

    assert_equal "msg_truffle_1", item[:id]
    refute item.key?(:phase)
  end

  def test_overlong_message_id_is_folded_through_short_hash
    long_id = "msg_#{"x" * 80}"
    signature = Items.encode_text_signature(long_id)
    msg = Truffle::Message.assistant(
      content: [Truffle::Content::Text.new(text: "hi", signature: signature)]
    )
    item = build([msg])[:input].first

    assert_equal "msg_#{Truffle::ShortHash.of(long_id)}", item[:id]
    assert_operator item[:id].length, :<=, 64
  end

  def test_assistant_items_preserve_content_order
    msg = Truffle::Message.assistant(content: [
                                       Truffle::Content::Thinking.new(
                                         thinking: "pondered", signature: reasoning_signature
                                       ),
                                       Truffle::Content::Text.new(text: "Adding now."),
                                       Truffle::ToolCall.new(id: "call_1", name: "add",
                                                             arguments: { "a" => 1 })
                                     ])
    types = build([msg])[:input].map { |item| item[:type] || item["type"] }

    assert_equal %w[reasoning message function_call], types
  end

  # --- deserialize_message ---------------------------------------------------

  def output_fixture
    [
      { "type" => "reasoning", "id" => "rs_1",
        "summary" => [{ "type" => "summary_text", "text" => "step one" },
                      { "type" => "summary_text", "text" => "step two" }],
        "encrypted_content" => "enc-xyz" },
      { "type" => "message", "id" => "msg_1", "role" => "assistant",
        "status" => "completed", "phase" => "final_answer",
        "content" => [{ "type" => "output_text", "text" => "Done.", "annotations" => [] }] },
      { "type" => "function_call", "id" => "fc_1", "call_id" => "call_9",
        "name" => "add", "arguments" => '{"a":1,"b":2}' }
    ]
  end

  def test_deserialize_maps_items_onto_typed_blocks_in_wire_order
    message = Items.deserialize_message(output_fixture)
    types = message.content.map(&:type)

    assert_equal %i[thinking text tool_call], types
    assert_equal "step one\n\nstep two", message.content.first.thinking
    assert_equal "Done.", message.text

    call = message.tool_calls.first

    assert_equal "call_9", call.id
    assert_equal "add", call.name
    assert_equal({ "a" => 1, "b" => 2 }, call.arguments)
  end

  def test_reasoning_item_survives_a_serialize_parse_serialize_round_trip
    message = Items.deserialize_message(output_fixture)
    replayed = Items.convert_messages([message])

    assert_equal output_fixture.first, replayed.first
  end

  def test_message_id_and_phase_survive_the_round_trip
    message = Items.deserialize_message(output_fixture)
    item = Items.convert_messages([message])[1]

    assert_equal "msg_1", item[:id]
    assert_equal "final_answer", item[:phase]
  end

  def test_reasoning_round_trip_survives_a_session_json_cycle
    # Sessions persist messages through Message#to_h and JSON; the signature
    # must still replay the identical reasoning item after that cycle.
    message = Items.deserialize_message(output_fixture)
    restored = Truffle::Message.from_h(JSON.parse(JSON.generate(message.to_h)))
    replayed = Items.convert_messages([restored])

    assert_equal output_fixture.first, replayed.first
    assert_equal "msg_1", replayed[1][:id]
  end

  def test_deserialize_refusal_part_reads_as_text
    output = [{ "type" => "message", "id" => "msg_1", "role" => "assistant",
                "content" => [{ "type" => "refusal", "refusal" => "cannot help" }] }]

    assert_equal "cannot help", Items.deserialize_message(output).text
  end

  def test_deserialize_reasoning_without_summary_falls_back_to_content_text
    output = [{ "type" => "reasoning", "id" => "rs_1", "summary" => [],
                "content" => [{ "type" => "reasoning_text", "text" => "raw thought" }] }]

    assert_equal "raw thought", Items.deserialize_message(output).content.first.thinking
  end

  # --- structured output: text.format seam ----------------------------------

  def test_schema_emits_text_format_json_schema
    schema = Truffle::Schema.build { param :city, :string, "City name", required: true }
    body = build([Truffle::Message.user("hi")], options: { schema: schema })
    format = body[:text][:format]

    assert_equal "json_schema", format[:type]
    assert_equal "response", format[:name]
    assert_equal schema.to_h, format[:schema]
    refute format[:strict]
  end

  def test_no_schema_omits_text_format
    refute build([Truffle::Message.user("hi")]).key?(:text)
  end

  # --- map_stop_reason --------------------------------------------------------

  def test_map_stop_reason_completed_is_a_clean_stop
    assert_equal [Truffle::StopReason::STOP, nil], Items.map_stop_reason("completed")
  end

  def test_map_stop_reason_incomplete_is_a_length_cutoff
    stop, err = Items.map_stop_reason("incomplete", incomplete_reason: "max_output_tokens")

    assert_equal Truffle::StopReason::LENGTH, stop
    assert_nil err
  end

  def test_map_stop_reason_incomplete_content_filter_is_an_error
    stop, err = Items.map_stop_reason("incomplete", incomplete_reason: "content_filter")

    assert_equal Truffle::StopReason::ERROR, stop
    assert_includes err, "content_filter"
  end

  def test_map_stop_reason_failed_carries_the_response_error
    stop, err = Items.map_stop_reason(
      "failed", error: { "code" => "server_error", "message" => "boom" }
    )

    assert_equal Truffle::StopReason::ERROR, stop
    assert_equal "server_error: boom", err
  end

  def test_map_stop_reason_unknown_folds_into_error_with_raw_status
    stop, err = Items.map_stop_reason("brand_new_status")

    assert_equal Truffle::StopReason::ERROR, stop
    assert_includes err, "brand_new_status"
  end

  # --- Usage.from_openai_responses ---------------------------------------------

  def test_usage_input_is_the_residual_after_cached_tokens
    raw = { "input_tokens" => 100, "output_tokens" => 20,
            "input_tokens_details" => { "cached_tokens" => 40 },
            "output_tokens_details" => { "reasoning_tokens" => 7 } }
    usage = Truffle::Usage.from_openai_responses(raw)

    assert_equal 60, usage.input
    assert_equal 40, usage.cache_read
    assert_equal 20, usage.output
    assert_equal 7, usage.reasoning
    assert_equal 0, usage.cache_write
  end

  def test_usage_prices_against_the_catalog
    raw = { "input_tokens" => 1_000_000, "output_tokens" => 1_000_000 }
    pricing = Truffle::Pricing.cost_for("gpt-5.5")
    usage = Truffle::Usage.from_openai_responses(raw, pricing: pricing)
    # gpt-5.5: $5/M input, $30/M output.
    assert_in_delta 5.0, usage.cost.input, 1e-9
    assert_in_delta 30.0, usage.cost.output, 1e-9
    assert_in_delta 35.0, usage.cost.total, 1e-9
  end

  # --- registry wiring ---------------------------------------------------------

  def test_openai_responses_registered_as_a_provider
    provider = Truffle.provider(:openai_responses, api_key: "test-key")

    assert_kind_of Truffle::Providers::OpenAIResponses, provider
    assert_equal "openai_responses", provider.name
    assert_equal "gpt-5.5", provider.model
  end

  def test_missing_api_key_raises
    assert_raises(ArgumentError) { Truffle::Providers::OpenAIResponses.new(api_key: "") }
  end
end
