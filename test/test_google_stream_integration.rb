# frozen_string_literal: true

require "test_helper"

# End-to-end streaming test against the real Gemini streamGenerateContent SSE
# endpoint. Skipped unless GEMINI_API_KEY is set so the default `rake test` stays
# hermetic. Verifies that #chat_stream yields the event protocol in order and
# returns a final Response whose message matches the concatenated text deltas.
class TestGoogleStreamIntegration < Minitest::Test
  def setup
    return unless ENV["GEMINI_API_KEY"].to_s.empty?

    skip "set GEMINI_API_KEY to run the live Google streaming test"
  end

  def test_streams_text_from_real_model
    provider = Truffle::Providers::Google.new(model: "gemini-2.5-flash-lite")
    messages = [
      Truffle::Message.user(
        "Return exactly the four lowercase letters pong. " \
        "No spaces, punctuation, explanation, or quotes."
      )
    ]

    events = []
    response = provider.chat_stream(messages: messages, temperature: 0) do |event|
      events << event
    end

    assert_equal :start, events.first.type
    assert_predicate events.last, :terminal?, "stream must end on a terminal event"
    refute_predicate events.last, :error?,
                     "expected a clean stop, got: #{events.last.error_message}"

    streamed_text = events.select { |e| e.type == :text_delta }.map(&:delta).join

    assert_equal response.message.text, streamed_text
    assert_equal "pong", response.message.text.to_s.strip.downcase
    assert_equal Truffle::StopReason::STOP, response.stop_reason
  end
end
