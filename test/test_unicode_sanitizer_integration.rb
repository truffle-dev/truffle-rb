# frozen_string_literal: true

require "test_helper"

# Live provider smoke for the outbound Unicode sanitizer. The offline provider
# tests prove the request bodies are sanitized; these tests prove the same
# malformed input can pass through real provider HTTP calls. They skip unless the
# matching key is present, preserving the offline default suite.
class TestUnicodeSanitizerIntegration < Minitest::Test
  LONE_HIGH = [0xD83D].pack("U")

  def messages
    [
      Truffle::Message.system("Reply with exactly ok."),
      Truffle::Message.user("This message contains malformed surrogate bytes: #{LONE_HIGH}")
    ]
  end

  def assert_live_response(response)
    skip response.error_message if transient_high_demand?(response.error_message)

    refute_equal Truffle::StopReason::ERROR, response.stop_reason, response.error_message
    assert_match(/\bok\b/i, response.message.text.to_s)
  end

  def transient_high_demand?(message)
    message.to_s.include?("503") && message.to_s.include?("high demand")
  end

  def test_openai_accepts_sanitized_surrogate_text
    if ENV["OPENAI_API_KEY"].to_s.empty?
      skip "set OPENAI_API_KEY to run the live OpenAI sanitizer test"
    end

    provider = Truffle::Providers::OpenAI.new(model: "gpt-4o-mini")

    assert_live_response provider.chat(messages: messages, temperature: 0)
  end

  def test_anthropic_accepts_sanitized_surrogate_text
    if ENV["ANTHROPIC_API_KEY"].to_s.empty?
      skip "set ANTHROPIC_API_KEY to run the live Anthropic sanitizer test"
    end

    provider = Truffle::Providers::Anthropic.new(model: "claude-haiku-4-5")

    assert_live_response provider.chat(messages: messages, temperature: 0)
  end

  def test_google_accepts_sanitized_surrogate_text
    if ENV["GEMINI_API_KEY"].to_s.empty?
      skip "set GEMINI_API_KEY to run the live Google sanitizer test"
    end

    provider = Truffle::Providers::Google.new(model: "gemini-2.5-flash-lite")

    assert_live_response provider.chat(messages: messages, temperature: 0)
  end
end
