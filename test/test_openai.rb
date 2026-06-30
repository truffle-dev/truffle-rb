# frozen_string_literal: true

require "test_helper"

class TestOpenAIProvider < Minitest::Test
  def body_for(provider, model:, options:)
    provider.send(:build_chat_body, [Truffle::Message.user("hi")], [], model, options)
  end

  def test_reasoning_models_use_max_completion_tokens_on_native_openai
    provider = Truffle::Providers::OpenAI.new(api_key: "test-key")

    body = body_for(provider, model: "gpt-5", options: { max_tokens: 2048 })

    assert_equal 2048, body[:max_completion_tokens]
    refute_includes body, :max_tokens
  end

  def test_non_reasoning_models_keep_max_tokens
    provider = Truffle::Providers::OpenAI.new(api_key: "test-key")

    body = body_for(provider, model: "gpt-4o-mini", options: { max_tokens: 1024 })

    assert_equal 1024, body[:max_tokens]
    refute_includes body, :max_completion_tokens
  end

  def test_custom_openai_compatible_endpoints_keep_max_tokens
    provider = Truffle::Providers::OpenAI.new(
      api_key: "test-key",
      base_url: "https://example.test/v1",
      provider_name: "custom"
    )

    body = body_for(provider, model: "gpt-5", options: { max_tokens: 512 })

    assert_equal 512, body[:max_tokens]
    refute_includes body, :max_completion_tokens
  end

  def test_explicit_max_completion_tokens_wins
    provider = Truffle::Providers::OpenAI.new(api_key: "test-key")

    body = body_for(provider, model: "gpt-5",
                              options: { max_tokens: 512, max_completion_tokens: 256 })

    assert_equal 256, body[:max_completion_tokens]
    refute_includes body, :max_tokens
  end

  def test_user_content_with_image_becomes_chat_completions_blocks
    provider = Truffle::Providers::OpenAI.new(api_key: "test-key")
    image = Truffle::Content::Image.new(data: "base64data", mime_type: "image/png")
    message = Truffle::Message.user([Truffle::Content::Text.new(text: "look"), image])
    body = provider.send(:build_chat_body, [message], [], "gpt-4o-mini", {})

    content = body[:messages].first[:content]

    assert_equal [
      { type: "text", text: "look" },
      {
        type: "image_url",
        image_url: { url: "data:image/png;base64,base64data" }
      }
    ], content
  end

  # --- structured output: response_format schema seam --------------------

  def schema_fixture
    Truffle::Schema.build { param :city, :string, "City name", required: true }
  end

  def test_schema_emits_response_format_json_schema_on_native_endpoint
    provider = Truffle::Providers::OpenAI.new(api_key: "test-key")
    body = body_for(provider, model: "gpt-4o-mini", options: { schema: schema_fixture })

    rf = body[:response_format]

    assert_equal "json_schema", rf[:type]
    assert_equal "response", rf[:json_schema][:name]
    assert_equal schema_fixture.to_h, rf[:json_schema][:schema]
    refute rf[:json_schema][:strict], "strict defaults off"
  end

  def test_schema_name_and_strict_options_are_honored
    provider = Truffle::Providers::OpenAI.new(api_key: "test-key")
    opts = { schema: schema_fixture, schema_name: "weather", strict: true }
    body = body_for(provider, model: "gpt-4o-mini", options: opts)

    json_schema = body[:response_format][:json_schema]

    assert_equal "weather", json_schema[:name]
    assert json_schema[:strict]
  end

  def test_schema_accepts_a_plain_hash
    provider = Truffle::Providers::OpenAI.new(api_key: "test-key")
    raw = { type: "object", properties: { "n" => { type: "number" } }, required: ["n"] }
    body = body_for(provider, model: "gpt-4o-mini", options: { schema: raw })

    assert_equal raw, body[:response_format][:json_schema][:schema]
  end

  def test_schema_is_dropped_on_non_native_endpoint
    provider = Truffle::Providers::OpenAI.new(
      api_key: "test-key", base_url: "https://example.test/v1", provider_name: "custom"
    )
    body = body_for(provider, model: "gpt-4o-mini", options: { schema: schema_fixture })

    refute_includes body, :response_format
  end

  def test_no_schema_means_no_response_format
    provider = Truffle::Providers::OpenAI.new(api_key: "test-key")
    body = body_for(provider, model: "gpt-4o-mini", options: {})

    refute_includes body, :response_format
  end
end
