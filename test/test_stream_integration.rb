# frozen_string_literal: true

require "test_helper"

# End-to-end streaming test against the real OpenAI API. Skipped unless
# OPENAI_API_KEY is set so the default `rake test` stays hermetic. Verifies that
# #chat_stream yields the event protocol in order and returns a final Response
# whose message matches the concatenated text deltas.
class TestStreamIntegration < Minitest::Test
  def setup
    skip "set OPENAI_API_KEY to run the live streaming test" if ENV["OPENAI_API_KEY"].to_s.empty?
  end

  def test_streams_text_from_real_model
    provider = Truffle::Providers::OpenAI.new(model: "gpt-4o-mini")
    messages = [Truffle::Message.user("Say the word 'pong' and nothing else.")]

    events = []
    response = provider.chat_stream(messages: messages) { |event| events << event }

    assert_equal :start, events.first.type
    assert events.last.terminal?, "stream must end on a terminal event"
    refute events.last.error?, "expected a clean stop, got: #{events.last.error_message}"

    streamed_text = events.select { |e| e.type == :text_delta }.map(&:delta).join
    assert_equal response.message.text, streamed_text
    assert_includes response.message.text.downcase, "pong"
    assert_equal Truffle::StopReason::STOP, response.stop_reason
  end
end
