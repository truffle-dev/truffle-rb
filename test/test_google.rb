# frozen_string_literal: true

require "test_helper"

# Pins the Google Gemini provider's pure wire transforms: building the
# generateContent body (system extraction into systemInstruction, Content roles,
# tool functionDeclarations, tool-result coalescing, part shapes), deserializing
# a candidate into a message, mapping finish reasons, validating thought
# signatures, and parsing usageMetadata. These are class methods fed hand-built
# data, so the whole suite runs offline with no api_key and no network; the live
# round-trip is in test_google_integration.rb.
class TestGoogle < Minitest::Test
  Google = Truffle::Providers::Google

  # A valid base64 thought signature (Gemini's TYPE_BYTES field): "sig".
  VALID_SIG = "c2ln"

  def add_tool
    Truffle::Tool.define("add", "Add two integers") do
      param :a, :integer, "first addend", required: true
      param :b, :integer, "second addend", required: true
      run { |a:, b:| a + b }
    end
  end

  # --- build_body: system extraction -------------------------------------

  def test_system_message_becomes_system_instruction_not_a_message
    messages = [
      Truffle::Message.system("You are precise."),
      Truffle::Message.user("hi")
    ]
    body = Google.build_body(messages, [])

    assert_equal({ parts: [{ text: "You are precise." }] }, body[:systemInstruction])
    roles = body[:contents].map { |c| c[:role] }

    assert_equal %w[user], roles
  end

  def test_multiple_system_messages_join
    messages = [
      Truffle::Message.system("One."),
      Truffle::Message.system("Two."),
      Truffle::Message.user("hi")
    ]
    body = Google.build_body(messages, [])

    assert_equal "One.\nTwo.", body[:systemInstruction][:parts].first[:text]
  end

  def test_no_system_message_omits_the_field
    body = Google.build_body([Truffle::Message.user("hi")], [])

    refute body.key?(:systemInstruction)
  end

  # --- build_body: tools and generation config ---------------------------

  def test_tools_convert_to_function_declarations_with_json_schema
    body = Google.build_body([Truffle::Message.user("hi")], [add_tool.to_schema])
    decl = body[:tools].first[:functionDeclarations].first

    assert_equal "add", decl[:name]
    assert_equal "Add two integers", decl[:description]
    assert_equal "object", decl[:parametersJsonSchema][:type]
    assert_equal %w[a b], decl[:parametersJsonSchema][:required]
    assert decl[:parametersJsonSchema][:properties].key?("a")
    # The neutral "parameters" key must not leak onto the Gemini declaration.
    refute decl.key?(:parameters)
  end

  def test_no_tools_omits_tools_and_tool_config
    body = Google.build_body([Truffle::Message.user("hi")], [])

    refute body.key?(:tools)
    refute body.key?(:toolConfig)
  end

  def test_tool_choice_maps_to_function_calling_config_mode
    body = Google.build_body([Truffle::Message.user("hi")], [add_tool.to_schema],
                             { tool_choice: "any" })

    assert_equal "ANY", body[:toolConfig][:functionCallingConfig][:mode]
  end

  def test_tool_choice_omitted_when_not_given_even_with_tools
    body = Google.build_body([Truffle::Message.user("hi")], [add_tool.to_schema])

    refute body.key?(:toolConfig)
  end

  def test_generation_config_carries_temperature_and_max_tokens
    body = Google.build_body([Truffle::Message.user("hi")], [],
                             { temperature: 0.2, max_tokens: 256 })

    assert_in_delta 0.2, body[:generationConfig][:temperature], 1e-9
    assert_equal 256, body[:generationConfig][:maxOutputTokens]
  end

  def test_generation_config_omitted_when_no_options
    body = Google.build_body([Truffle::Message.user("hi")], [])

    refute body.key?(:generationConfig)
  end

  def test_model_id_does_not_ride_in_the_body
    # Gemini puts the model in the URL path, so the body never carries it.
    body = Google.build_body([Truffle::Message.user("hi")], [])

    refute body.key?(:model)
  end

  # --- map_tool_choice ---------------------------------------------------

  def test_map_tool_choice_modes
    assert_equal "NONE", Google.map_tool_choice("none")
    assert_equal "ANY", Google.map_tool_choice("any")
    assert_equal "AUTO", Google.map_tool_choice("auto")
    assert_equal "AUTO", Google.map_tool_choice("anything-else")
  end

  # --- convert_messages: roles and part shapes ---------------------------

  def test_user_text_becomes_a_user_content_with_a_text_part
    body = Google.build_body([Truffle::Message.user("what is 2+2?")], [])
    content = body[:contents].first

    assert_equal "user", content[:role]
    assert_equal([{ text: "what is 2+2?" }], content[:parts])
  end

  def test_user_image_becomes_inline_data
    image = Truffle::Content::Image.new(data: "base64data", mime_type: "image/png")
    msg = Truffle::Message.user([Truffle::Content::Text.new(text: "look"), image])
    parts = Google.user_parts(msg.content)

    text = parts.find { |p| p.key?(:text) }
    inline = parts.find { |p| p.key?(:inlineData) }

    assert_equal "look", text[:text]
    assert_equal "image/png", inline[:inlineData][:mimeType]
    assert_equal "base64data", inline[:inlineData][:data]
  end

  def test_assistant_becomes_role_model_with_text_and_function_call
    assistant = Truffle::Message.assistant(
      content: "Let me add those.",
      tool_calls: [Truffle::ToolCall.new(id: "call_1", name: "add",
                                         arguments: { "a" => 2, "b" => 3 })]
    )
    parts = Google.model_parts(assistant)

    text = parts.find { |p| p.key?(:text) }
    call = parts.find { |p| p.key?(:functionCall) }

    assert_equal "Let me add those.", text[:text]
    assert_equal "add", call[:functionCall][:name]
    assert_equal({ "a" => 2, "b" => 3 }, call[:functionCall][:args])
  end

  def test_empty_assistant_text_part_is_dropped
    assistant = Truffle::Message.assistant(
      content: "   ",
      tool_calls: [Truffle::ToolCall.new(id: "c", name: "add", arguments: {})]
    )
    parts = Google.model_parts(assistant)

    assert_equal 1, parts.length
    assert parts.first.key?(:functionCall)
  end

  def test_signed_thinking_block_becomes_a_thought_part
    msg = Truffle::Message.assistant(
      content: [Truffle::Content::Thinking.new(thinking: "ponder", signature: VALID_SIG)]
    )
    part = Google.model_parts(msg).first

    assert part[:thought]
    assert_equal "ponder", part[:text]
    assert_equal VALID_SIG, part[:thoughtSignature]
  end

  def test_unsigned_thinking_block_downgrades_to_text
    # Gemini rejects a thought part without a valid signature on replay, so an
    # unsigned (or foreign-model) thinking block becomes a plain text part.
    msg = Truffle::Message.assistant(
      content: [Truffle::Content::Thinking.new(thinking: "ponder", signature: nil)]
    )
    part = Google.model_parts(msg).first

    refute part.key?(:thought)
    assert_equal "ponder", part[:text]
    refute part.key?(:thoughtSignature)
  end

  def test_text_part_keeps_a_valid_thought_signature
    msg = Truffle::Message.assistant(
      content: [Truffle::Content::Text.new(text: "answer", signature: VALID_SIG)]
    )
    part = Google.model_parts(msg).first

    assert_equal "answer", part[:text]
    assert_equal VALID_SIG, part[:thoughtSignature]
  end

  def test_text_part_drops_an_invalid_thought_signature
    msg = Truffle::Message.assistant(
      content: [Truffle::Content::Text.new(text: "answer", signature: "not base64!!")]
    )
    part = Google.model_parts(msg).first

    refute part.key?(:thoughtSignature)
  end

  # --- convert_messages: tool-result coalescing --------------------------

  def test_single_tool_result_becomes_a_user_function_response
    messages = [
      Truffle::Message.user("add 2 and 3"),
      Truffle::Message.assistant(
        tool_calls: [Truffle::ToolCall.new(id: "call_1", name: "add",
                                           arguments: { "a" => 2, "b" => 3 })]
      ),
      Truffle::Message.tool(content: "5", tool_call_id: "call_1", name: "add")
    ]
    body = Google.build_body(messages, [])
    result = body[:contents].last

    assert_equal "user", result[:role]
    fr = result[:parts].first[:functionResponse]

    assert_equal "add", fr[:name]
    assert_equal "5", fr[:response][:output]
  end

  def test_consecutive_tool_results_coalesce_into_one_user_turn
    messages = [
      Truffle::Message.assistant(
        tool_calls: [
          Truffle::ToolCall.new(id: "c1", name: "add", arguments: {}),
          Truffle::ToolCall.new(id: "c2", name: "mul", arguments: {})
        ]
      ),
      Truffle::Message.tool(content: "5", tool_call_id: "c1", name: "add"),
      Truffle::Message.tool(content: "9", tool_call_id: "c2", name: "mul")
    ]
    body = Google.build_body(messages, [])

    # Both function responses fold into one user turn, the shape Gemini expects.
    user_turns = body[:contents].select { |c| c[:role] == "user" }

    assert_equal 1, user_turns.length
    names = user_turns.first[:parts].map { |p| p[:functionResponse][:name] }

    assert_equal %w[add mul], names
  end

  # --- deserialize_message -----------------------------------------------

  def test_deserialize_text_and_function_call
    content = {
      "parts" => [
        { "text" => "Here you go." },
        { "functionCall" => { "name" => "add", "args" => { "a" => 1, "b" => 2 } } }
      ]
    }
    message = Google.deserialize_message(content)

    assert_equal "Here you go.", message.text
    call = message.tool_calls.first

    assert_equal "add", call.name
    assert_equal({ "a" => 1, "b" => 2 }, call.arguments)
  end

  def test_deserialize_synthesizes_a_call_id_when_absent
    content = { "parts" => [{ "functionCall" => { "name" => "add", "args" => {} } }] }
    call = Google.deserialize_message(content).tool_calls.first

    # Gemini rarely returns a call id over REST, so a deterministic one is
    # synthesized from the function name and its position.
    assert_equal "add-0", call.id
  end

  def test_deserialize_keeps_an_explicit_call_id
    content = { "parts" => [{ "functionCall" =>
      { "id" => "real-id", "name" => "add", "args" => {} } }] }
    call = Google.deserialize_message(content).tool_calls.first

    assert_equal "real-id", call.id
  end

  def test_deserialize_thought_part_becomes_thinking
    content = {
      "parts" => [
        { "thought" => true, "text" => "reasoned", "thoughtSignature" => VALID_SIG }
      ]
    }
    thinking = Google.deserialize_message(content).content.grep(Truffle::Content::Thinking)

    assert_equal 1, thinking.length
    assert_equal "reasoned", thinking.first.thinking
    assert_equal VALID_SIG, thinking.first.signature
  end

  def test_deserialize_missing_args_defaults_to_empty_hash
    content = { "parts" => [{ "functionCall" => { "name" => "noop" } }] }
    call = Google.deserialize_message(content).tool_calls.first

    assert_equal({}, call.arguments)
  end

  def test_deserialize_nil_content_is_an_empty_message
    message = Google.deserialize_message(nil)

    assert_empty message.content
    assert_empty message.tool_calls
  end

  # --- map_stop_reason ---------------------------------------------------

  def test_map_stop_reason_clean_stop
    assert_equal [Truffle::StopReason::STOP, nil], Google.map_stop_reason("STOP")
    assert_equal [Truffle::StopReason::STOP, nil], Google.map_stop_reason(nil)
  end

  def test_map_stop_reason_max_tokens_is_length
    assert_equal [Truffle::StopReason::LENGTH, nil], Google.map_stop_reason("MAX_TOKENS")
  end

  def test_map_stop_reason_safety_folds_into_error_with_raw_reason
    stop, err = Google.map_stop_reason("SAFETY")

    assert_equal Truffle::StopReason::ERROR, stop
    assert_includes err, "SAFETY"
  end

  # --- valid_signature? --------------------------------------------------

  def test_valid_signature_accepts_base64_multiple_of_four
    assert Google.valid_signature?(VALID_SIG)
    assert Google.valid_signature?("YWJjZA==")
  end

  def test_valid_signature_rejects_empty_nil_and_non_base64
    refute Google.valid_signature?(nil)
    refute Google.valid_signature?("")
    refute Google.valid_signature?("abc") # length 3, not a multiple of four
    refute Google.valid_signature?("not base64!") # spaces and punctuation
  end

  # --- Usage.from_google -------------------------------------------------

  def test_usage_input_is_the_residual_after_cached_tokens
    raw = { "promptTokenCount" => 100, "candidatesTokenCount" => 20,
            "cachedContentTokenCount" => 40 }
    usage = Truffle::Usage.from_google(raw)

    assert_equal 60, usage.input
    assert_equal 20, usage.output
    assert_equal 40, usage.cache_read
    assert_equal 0, usage.cache_write
  end

  def test_usage_output_includes_thought_tokens_and_records_reasoning
    raw = { "promptTokenCount" => 10, "candidatesTokenCount" => 5,
            "thoughtsTokenCount" => 7 }
    usage = Truffle::Usage.from_google(raw)

    assert_equal 12, usage.output
    assert_equal 7, usage.reasoning
  end

  def test_usage_residual_never_goes_negative
    raw = { "promptTokenCount" => 10, "cachedContentTokenCount" => 40 }
    usage = Truffle::Usage.from_google(raw)

    assert_equal 0, usage.input
  end

  def test_usage_prices_against_the_google_table
    raw = { "promptTokenCount" => 1_000_000, "candidatesTokenCount" => 1_000_000 }
    pricing = Truffle::Pricing.cost_for("gemini-2.5-flash")
    usage = Truffle::Usage.from_google(raw, pricing: pricing)
    # gemini-2.5-flash: $0.30/M input, $2.50/M output.
    assert_in_delta 0.3, usage.cost.input, 1e-9
    assert_in_delta 2.5, usage.cost.output, 1e-9
    assert_in_delta 2.8, usage.cost.total, 1e-9
  end

  # --- registry wiring ---------------------------------------------------

  def test_google_registered_as_a_provider
    provider = Truffle.provider(:google, api_key: "test-key")

    assert_kind_of Truffle::Providers::Google, provider
    assert_equal "google", provider.name
  end

  def test_missing_api_key_raises
    assert_raises(ArgumentError) { Truffle::Providers::Google.new(api_key: "") }
  end
end
