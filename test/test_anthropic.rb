# frozen_string_literal: true

require "test_helper"

# Pins the Anthropic provider's pure wire transforms: building the request body
# (system extraction, max_tokens, tool schema, tool-result coalescing, content
# block shapes), deserializing a response message, mapping stop reasons, and
# parsing usage. These are class methods fed hand-built data, so the whole suite
# runs offline with no api_key and no network; the live round-trip is in
# test_anthropic_integration.rb.
class TestAnthropic < Minitest::Test
  Anthropic = Truffle::Providers::Anthropic

  def add_tool
    Truffle::Tool.define("add", "Add two integers") do
      param :a, :integer, "first addend", required: true
      param :b, :integer, "second addend", required: true
      run { |a:, b:| a + b }
    end
  end

  # --- build_body: thinking, effort, caching -----------------------------

  def test_thinking_option_lands_in_the_body
    body = Anthropic.build_body([Truffle::Message.user("hi")], [], "m", 100,
                                { thinking: { type: "adaptive", display: "summarized" } })
    assert_equal({ type: "adaptive", display: "summarized" }, body[:thinking])
  end

  def test_effort_merges_into_output_config_alongside_a_schema_format
    schema = { type: "object", properties: {} }
    body = Anthropic.build_body([Truffle::Message.user("hi")], [], "m", 100,
                                { effort: "medium", schema: schema })
    assert_equal "medium", body[:output_config][:effort]
    assert body[:output_config][:format], "schema format should survive the effort merge"
  end

  def test_cache_option_adds_top_level_ephemeral_cache_control
    body = Anthropic.build_body([Truffle::Message.user("hi")], [], "m", 100, { cache: true })
    assert_equal({ type: "ephemeral" }, body[:cache_control])
  end

  def test_no_thinking_effort_or_cache_keys_by_default
    body = Anthropic.build_body([Truffle::Message.user("hi")], [], "m", 100, {})
    refute body.key?(:thinking)
    refute body.key?(:cache_control)
    refute body.key?(:output_config)
  end

  def test_constructor_defaults_flow_into_requests_and_per_call_options_win
    provider = Anthropic.new(api_key: "k", thinking: { type: "adaptive" }, effort: "high", cache: true)
    defaults = provider.send(:request_defaults)
    assert_equal({ type: "adaptive" }, defaults[:thinking])
    assert_equal "high", defaults[:effort]
    assert defaults[:cache]
    merged = defaults.merge({ effort: "low" })
    assert_equal "low", merged[:effort]
  end

  # --- build_body: system extraction -------------------------------------

  def test_system_message_becomes_top_level_field_not_a_message
    messages = [
      Truffle::Message.system("You are precise."),
      Truffle::Message.user("hi")
    ]
    body = Anthropic.build_body(messages, [], "claude-sonnet-4-5", 4096)

    assert_equal "You are precise.", body[:system]
    roles = body[:messages].map { |m| m[:role] }

    refute_includes roles, "system"
    assert_equal %w[user], roles
  end

  def test_multiple_system_messages_join
    messages = [
      Truffle::Message.system("One."),
      Truffle::Message.system("Two."),
      Truffle::Message.user("hi")
    ]
    body = Anthropic.build_body(messages, [], "claude-sonnet-4-5", 4096)

    assert_equal "One.\nTwo.", body[:system]
  end

  def test_no_system_message_omits_the_field
    body = Anthropic.build_body([Truffle::Message.user("hi")], [], "claude-sonnet-4-5", 4096)

    refute body.key?(:system)
  end

  # --- build_body: required max_tokens and tools -------------------------

  def test_max_tokens_is_always_present
    body = Anthropic.build_body([Truffle::Message.user("hi")], [], "claude-sonnet-4-5", 512)

    assert_equal 512, body[:max_tokens]
  end

  def test_tools_convert_to_input_schema
    body = Anthropic.build_body([Truffle::Message.user("hi")], [add_tool.to_schema],
                                "claude-sonnet-4-5", 4096)
    tool = body[:tools].first

    assert_equal "add", tool[:name]
    assert_equal "Add two integers", tool[:description]
    assert_equal "object", tool[:input_schema][:type]
    assert_equal %w[a b], tool[:input_schema][:required]
    assert tool[:input_schema][:properties].key?("a")
    # The neutral "parameters" key must not leak onto the Anthropic tool.
    refute tool.key?(:parameters)
  end

  def test_no_tools_omits_tools_and_tool_choice
    body = Anthropic.build_body([Truffle::Message.user("hi")], [], "claude-sonnet-4-5", 4096)

    refute body.key?(:tools)
    refute body.key?(:tool_choice)
  end

  def test_string_tool_choice_wraps_into_typed_object
    body = Anthropic.build_body([Truffle::Message.user("hi")], [add_tool.to_schema],
                                "claude-sonnet-4-5", 4096, { tool_choice: "any" })

    assert_equal({ type: "any" }, body[:tool_choice])
  end

  def test_temperature_passes_through_when_given
    body = Anthropic.build_body([Truffle::Message.user("hi")], [], "claude-sonnet-4-5",
                                4096, { temperature: 0.2 })

    assert_in_delta 0.2, body[:temperature], 1e-9
    body2 = Anthropic.build_body([Truffle::Message.user("hi")], [], "claude-sonnet-4-5", 4096)

    refute body2.key?(:temperature)
  end

  # --- convert_messages: roles and content shapes ------------------------

  def test_text_only_user_message_is_a_plain_string
    body = Anthropic.build_body([Truffle::Message.user("what is 2+2?")], [],
                                "claude-sonnet-4-5", 4096)
    msg = body[:messages].first

    assert_equal "user", msg[:role]
    assert_equal "what is 2+2?", msg[:content]
  end

  def test_assistant_text_and_tool_call_become_blocks
    assistant = Truffle::Message.assistant(
      content: "Let me add those.",
      tool_calls: [Truffle::ToolCall.new(id: "call_1", name: "add",
                                         arguments: { "a" => 2, "b" => 3 })]
    )
    blocks = Anthropic.assistant_blocks(assistant)

    text = blocks.find { |b| b[:type] == "text" }
    tool = blocks.find { |b| b[:type] == "tool_use" }

    assert_equal "Let me add those.", text[:text]
    assert_equal "call_1", tool[:id]
    assert_equal "add", tool[:name]
    assert_equal({ "a" => 2, "b" => 3 }, tool[:input])
  end

  def test_empty_assistant_text_block_is_dropped
    assistant = Truffle::Message.assistant(
      content: "   ",
      tool_calls: [Truffle::ToolCall.new(id: "c", name: "add", arguments: {})]
    )
    blocks = Anthropic.assistant_blocks(assistant)

    assert_equal(["tool_use"], blocks.map { |b| b[:type] })
  end

  def test_signed_thinking_block_is_preserved
    msg = Truffle::Message.assistant(
      content: [Truffle::Content::Thinking.new(thinking: "ponder", signature: "sig-abc")]
    )
    block = Anthropic.assistant_blocks(msg).first

    assert_equal "thinking", block[:type]
    assert_equal "ponder", block[:thinking]
    assert_equal "sig-abc", block[:signature]
  end

  def test_unsigned_thinking_block_downgrades_to_text
    # Anthropic rejects an unsigned thinking block on replay, so pi (and we)
    # downgrade it to plain text rather than send something the API will reject.
    msg = Truffle::Message.assistant(
      content: [Truffle::Content::Thinking.new(thinking: "ponder", signature: nil)]
    )
    block = Anthropic.assistant_blocks(msg).first

    assert_equal "text", block[:type]
    assert_equal "ponder", block[:text]
  end

  def test_redacted_thinking_block_passes_signature_as_data
    msg = Truffle::Message.assistant(
      content: [Truffle::Content::Thinking.new(thinking: "x", signature: "opaque", redacted: true)]
    )
    block = Anthropic.assistant_blocks(msg).first

    assert_equal "redacted_thinking", block[:type]
    assert_equal "opaque", block[:data]
  end

  # --- convert_messages: tool-result coalescing --------------------------

  def test_single_tool_result_becomes_a_user_tool_result_message
    messages = [
      Truffle::Message.user("add 2 and 3"),
      Truffle::Message.assistant(
        tool_calls: [Truffle::ToolCall.new(id: "call_1", name: "add",
                                           arguments: { "a" => 2, "b" => 3 })]
      ),
      Truffle::Message.tool(content: "5", tool_call_id: "call_1", name: "add")
    ]
    body = Anthropic.build_body(messages, [], "claude-sonnet-4-5", 4096)

    result_msg = body[:messages].last

    assert_equal "user", result_msg[:role]
    block = result_msg[:content].first

    assert_equal "tool_result", block[:type]
    assert_equal "call_1", block[:tool_use_id]
    assert_equal "5", block[:content]
  end

  def test_consecutive_tool_results_coalesce_into_one_user_message
    messages = [
      Truffle::Message.assistant(
        tool_calls: [
          Truffle::ToolCall.new(id: "c1", name: "add", arguments: {}),
          Truffle::ToolCall.new(id: "c2", name: "add", arguments: {})
        ]
      ),
      Truffle::Message.tool(content: "5", tool_call_id: "c1", name: "add"),
      Truffle::Message.tool(content: "9", tool_call_id: "c2", name: "add")
    ]
    body = Anthropic.build_body(messages, [], "claude-sonnet-4-5", 4096)

    # Two tool results fold into a single user message with two tool_result
    # blocks, not two separate user messages.
    user_messages = body[:messages].select { |m| m[:role] == "user" }

    assert_equal 1, user_messages.length
    ids = user_messages.first[:content].map { |b| b[:tool_use_id] }

    assert_equal %w[c1 c2], ids
  end

  # --- content blocks: images --------------------------------------------

  def test_user_content_with_image_becomes_block_array
    image = Truffle::Content::Image.new(data: "base64data", mime_type: "image/png")
    msg = Truffle::Message.user([Truffle::Content::Text.new(text: "look"), image])
    body = Anthropic.build_body([msg], [], "claude-sonnet-4-5", 4096)

    content = body[:messages].first[:content]

    assert_kind_of Array, content
    text = content.find { |b| b[:type] == "text" }
    img = content.find { |b| b[:type] == "image" }

    assert_equal "look", text[:text]
    assert_equal "base64", img[:source][:type]
    assert_equal "image/png", img[:source][:media_type]
    assert_equal "base64data", img[:source][:data]
  end

  def test_image_only_tool_result_gets_a_placeholder_text_block
    image = Truffle::Content::Image.new(data: "d", mime_type: "image/jpeg")
    msg = Truffle::Message.tool(content: [image], tool_call_id: "c1")
    block = Anthropic.tool_result_block(msg)
    types = block[:content].map { |b| b[:type] }

    assert_equal %w[text image], types
    assert_equal "(see attached image)", block[:content].first[:text]
  end

  # --- deserialize_message -----------------------------------------------

  def test_deserialize_text_and_tool_use
    content = [
      { "type" => "text", "text" => "Here you go." },
      { "type" => "tool_use", "id" => "call_9", "name" => "add", "input" => { "a" => 1, "b" => 2 } }
    ]
    message = Anthropic.deserialize_message(content)

    assert_equal "Here you go.", message.text
    call = message.tool_calls.first

    assert_equal "call_9", call.id
    assert_equal "add", call.name
    assert_equal({ "a" => 1, "b" => 2 }, call.arguments)
  end

  def test_deserialize_thinking_and_redacted_thinking
    content = [
      { "type" => "thinking", "thinking" => "reasoned", "signature" => "sig" },
      { "type" => "redacted_thinking", "data" => "opaque" }
    ]
    message = Anthropic.deserialize_message(content)
    thinking = message.content.grep(Truffle::Content::Thinking)

    assert_equal 2, thinking.length
    assert_equal "reasoned", thinking[0].thinking
    assert_equal "sig", thinking[0].signature
    assert_predicate thinking[1], :redacted?
    assert_equal "opaque", thinking[1].signature
  end

  def test_deserialize_tool_use_with_missing_input_defaults_to_empty_hash
    content = [{ "type" => "tool_use", "id" => "c", "name" => "noop" }]
    call = Anthropic.deserialize_message(content).tool_calls.first

    assert_equal({}, call.arguments)
  end

  def test_deserialize_repairs_string_tool_use_input
    content = [
      {
        "type" => "tool_use",
        "id" => "call_9",
        "name" => "note",
        "input" => "{\"body\":\"line one\nline two\"}"
      }
    ]

    call = Anthropic.deserialize_message(content).tool_calls.first

    assert_equal({ "body" => "line one\nline two" }, call.arguments)
  end

  def test_deserialize_keeps_unrepairable_string_tool_use_input_under_raw
    content = [
      { "type" => "tool_use", "id" => "call_9", "name" => "broken", "input" => "{not json" }
    ]

    call = Anthropic.deserialize_message(content).tool_calls.first

    assert_equal({ "_raw" => "{not json" }, call.arguments)
  end

  # --- map_stop_reason ---------------------------------------------------

  def test_map_stop_reason_clean_stops
    %w[end_turn stop_sequence pause_turn].each do |reason|
      stop, err = Anthropic.map_stop_reason(reason)

      assert_equal Truffle::StopReason::STOP, stop, "expected #{reason} -> stop"
      assert_nil err
    end
  end

  def test_map_stop_reason_length_and_tool_use
    assert_equal [Truffle::StopReason::LENGTH, nil], Anthropic.map_stop_reason("max_tokens")
    assert_equal [Truffle::StopReason::TOOL_USE, nil], Anthropic.map_stop_reason("tool_use")
  end

  def test_map_stop_reason_refusal_carries_explanation
    stop, err = Anthropic.map_stop_reason("refusal", { "explanation" => "not allowed" })

    assert_equal Truffle::StopReason::ERROR, stop
    assert_equal "not allowed", err
  end

  def test_map_stop_reason_refusal_without_details_has_default_message
    stop, err = Anthropic.map_stop_reason("refusal")

    assert_equal Truffle::StopReason::ERROR, stop
    assert_equal "The model refused to complete the request", err
  end

  def test_map_stop_reason_sensitive_is_an_error
    stop, err = Anthropic.map_stop_reason("sensitive")

    assert_equal Truffle::StopReason::ERROR, stop
    refute_nil err
  end

  def test_map_stop_reason_unknown_folds_into_error_with_raw_reason
    # pi throws on an unknown reason; we fold it into an error carrying the raw
    # reason, the same net behavior (an error) without crashing the loop.
    stop, err = Anthropic.map_stop_reason("brand_new_reason")

    assert_equal Truffle::StopReason::ERROR, stop
    assert_includes err, "brand_new_reason"
  end

  # --- Usage.from_anthropic ----------------------------------------------

  def test_usage_takes_input_tokens_directly_not_as_a_residual
    # Unlike OpenAI, Anthropic's input_tokens is already net of cache, so it is
    # used as-is rather than computed as prompt - cache_read - cache_write.
    raw = { "input_tokens" => 100, "output_tokens" => 20,
            "cache_read_input_tokens" => 40, "cache_creation_input_tokens" => 10 }
    usage = Truffle::Usage.from_anthropic(raw)

    assert_equal 100, usage.input
    assert_equal 20, usage.output
    assert_equal 40, usage.cache_read
    assert_equal 10, usage.cache_write
    assert_equal 170, usage.total_tokens
  end

  def test_usage_captures_1h_cache_write_and_reasoning_tokens
    raw = {
      "input_tokens" => 1, "output_tokens" => 1,
      "cache_creation_input_tokens" => 50,
      "cache_creation" => { "ephemeral_1h_input_tokens" => 30 },
      "output_tokens_details" => { "thinking_tokens" => 7 }
    }
    usage = Truffle::Usage.from_anthropic(raw)

    assert_equal 30, usage.cache_write_1h
    assert_equal 7, usage.reasoning
  end

  def test_usage_prices_against_anthropic_table
    raw = { "input_tokens" => 1_000_000, "output_tokens" => 1_000_000 }
    pricing = Truffle::Pricing.cost_for("claude-sonnet-4-5")
    usage = Truffle::Usage.from_anthropic(raw, pricing: pricing)
    # claude-sonnet-4-5: $3/M input, $15/M output.
    assert_in_delta 3.0, usage.cost.input, 1e-9
    assert_in_delta 15.0, usage.cost.output, 1e-9
    assert_in_delta 18.0, usage.cost.total, 1e-9
  end

  def test_usage_1h_cache_write_is_billed_at_twice_base_input
    # A 1h cache write costs 2x base input; a 5m write costs the cache_write rate.
    raw = {
      "input_tokens" => 0, "output_tokens" => 0,
      "cache_creation_input_tokens" => 1_000_000,
      "cache_creation" => { "ephemeral_1h_input_tokens" => 1_000_000 }
    }
    pricing = Truffle::Pricing.cost_for("claude-sonnet-4-5")
    usage = Truffle::Usage.from_anthropic(raw, pricing: pricing)
    # All 1M tokens are 1h writes: 1M * (3.0 * 2) / 1e6 = 6.0.
    assert_in_delta 6.0, usage.cost.cache_write, 1e-9
  end

  # --- pricing lookup ----------------------------------------------------

  def test_pricing_strips_dated_snapshot_for_anthropic_ids
    base = Truffle::Pricing.cost_for("claude-sonnet-4-5")
    dated = Truffle::Pricing.cost_for("claude-sonnet-4-5-20250929")

    assert_equal base, dated
  end

  def test_unknown_model_has_no_pricing
    assert_nil Truffle::Pricing.cost_for("some-unlisted-model")
  end

  # --- registry wiring ---------------------------------------------------

  def test_anthropic_registered_as_a_provider
    provider = Truffle.provider(:anthropic, api_key: "test-key")

    assert_kind_of Truffle::Providers::Anthropic, provider
    assert_equal "anthropic", provider.name
  end

  def test_missing_api_key_raises
    assert_raises(ArgumentError) { Truffle::Providers::Anthropic.new(api_key: "") }
  end

  # --- structured output: output_config seam -----------------------------

  def schema_fixture
    Truffle::Schema.build { param :city, :string, "City name", required: true }
  end

  def test_schema_emits_output_config_json_schema_format
    body = Anthropic.build_body([Truffle::Message.user("hi")], [], "claude-sonnet-4-5", 1024,
                                { schema: schema_fixture })
    fmt = body[:output_config][:format]

    assert_equal "json_schema", fmt[:type]
    assert_equal schema_fixture.to_h, fmt[:schema]
  end

  def test_schema_strips_top_level_strict_from_format_schema
    # Anthropic uses strict only for tool definitions, not JSON output, and
    # rejects it inside format.schema, so it is dropped.
    raw = { type: "object", strict: true, properties: { "n" => { type: "number" } } }
    body = Anthropic.build_body([Truffle::Message.user("hi")], [], "claude-sonnet-4-5", 1024,
                                { schema: raw })

    refute_includes body[:output_config][:format][:schema], :strict
  end

  def test_no_schema_omits_output_config
    body = Anthropic.build_body([Truffle::Message.user("hi")], [], "claude-sonnet-4-5", 1024)

    refute body.key?(:output_config)
  end
end
