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
end
