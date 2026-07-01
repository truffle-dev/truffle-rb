# frozen_string_literal: true

require "json"
require "test_helper"

# Provider-bound coverage for Truffle::UnicodeSanitizer. The sanitizer itself is
# pure; this file proves every built-in provider runs outbound text through it
# before building a JSON request body. That mirrors pi's provider serializers and
# avoids invalid UTF-8 errors before a request reaches the network.
class TestProviderUnicodeSanitization < Minitest::Test
  LONE_HIGH = [0xD83D].pack("U")

  def dirty(prefix, suffix)
    "#{prefix}#{LONE_HIGH}#{suffix}"
  end

  def assert_json_safe(body)
    JSON.generate(body)
  end

  def image
    Truffle::Content::Image.new(data: "base64data", mime_type: "image/png")
  end

  def text_block(text)
    Truffle::Content::Text.new(text: text)
  end

  def thinking_block(text)
    Truffle::Content::Thinking.new(thinking: text, signature: "sig-abc")
  end

  def test_openai_sanitizes_outbound_text_fields
    provider = Truffle::Providers::OpenAI.new(api_key: "test-key")
    messages = [
      Truffle::Message.system(dirty("system ", " prompt")),
      Truffle::Message.user(dirty("user ", " text")),
      Truffle::Message.user([text_block(dirty("block ", " text")), image]),
      Truffle::Message.assistant(content: dirty("assistant ", " text")),
      Truffle::Message.tool(content: dirty("tool ", " result"), tool_call_id: "call_1")
    ]

    body = provider.send(:build_chat_body, messages, [], "gpt-4o-mini", {})

    assert_equal "system  prompt", body[:messages][0][:content]
    assert_equal "user  text", body[:messages][1][:content]
    assert_equal "block  text", body[:messages][2][:content].first[:text]
    assert_equal "assistant  text", body[:messages][3][:content]
    assert_equal "tool  result", body[:messages][4][:content]
    assert_json_safe body
  end

  def test_anthropic_sanitizes_outbound_text_fields
    messages = [
      Truffle::Message.system(dirty("system ", " prompt")),
      Truffle::Message.user(dirty("user ", " text")),
      Truffle::Message.user([text_block(dirty("block ", " text")), image]),
      Truffle::Message.assistant(
        content: [text_block(dirty("assistant ", " text")),
                  thinking_block(dirty("thinking ", " text"))]
      ),
      Truffle::Message.tool(content: dirty("tool ", " result"), tool_call_id: "call_1")
    ]

    body = Truffle::Providers::Anthropic.build_body(messages, [], "claude-sonnet-4-5", 4096)
    assistant_blocks = body[:messages][2][:content]
    tool_result = body[:messages][3][:content].first

    assert_equal "system  prompt", body[:system]
    assert_equal "user  text", body[:messages][0][:content]
    assert_equal "block  text", body[:messages][1][:content].first[:text]
    assert_equal "assistant  text", assistant_blocks[0][:text]
    assert_equal "thinking  text", assistant_blocks[1][:thinking]
    assert_equal "tool  result", tool_result[:content]
    assert_json_safe body
  end

  def test_google_sanitizes_outbound_text_fields
    messages = [
      Truffle::Message.system(dirty("system ", " prompt")),
      Truffle::Message.user(dirty("user ", " text")),
      Truffle::Message.user([text_block(dirty("block ", " text")), image]),
      Truffle::Message.assistant(
        content: [text_block(dirty("assistant ", " text")),
                  thinking_block(dirty("thinking ", " text"))]
      ),
      Truffle::Message.tool(content: dirty("tool ", " result"), tool_call_id: "call_1",
                            name: "lookup")
    ]

    body = Truffle::Providers::Google.build_body(messages, [])
    actual = [
      body.dig(:systemInstruction, :parts, 0, :text),
      body.dig(:contents, 0, :parts, 0, :text),
      body.dig(:contents, 1, :parts, 0, :text),
      body.dig(:contents, 2, :parts, 0, :text),
      body.dig(:contents, 2, :parts, 1, :text),
      body.dig(:contents, 3, :parts, 0, :functionResponse, :response, :output)
    ]

    assert_equal [
      "system  prompt",
      "user  text",
      "block  text",
      "assistant  text",
      "thinking  text",
      "tool  result"
    ], actual
    assert_json_safe body
  end
end
