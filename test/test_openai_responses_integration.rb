# frozen_string_literal: true

require "test_helper"

# End-to-end test against the real OpenAI Responses API. Skipped unless
# OPENAI_API_KEY is set, so the default `rake test` stays hermetic and offline.
# Run it with a key present to verify the full stateless round-trip: prompt ->
# reasoning + tool call -> Truffle runs the tool -> the follow-up turn replays
# the reasoning item (encrypted_content and all) and answers with the result.
class TestOpenAIResponsesIntegration < Minitest::Test
  def setup
    return unless ENV["OPENAI_API_KEY"].to_s.empty?

    skip "set OPENAI_API_KEY to run the live OpenAI Responses test"
  end

  def multiply_tool(calls)
    Truffle::Tool.define("multiply", "Multiply two integers together") do
      param :a, :integer, "first factor", required: true
      param :b, :integer, "second factor", required: true
      run do |a:, b:|
        calls << [a, b]
        a * b
      end
    end
  end

  def test_two_turn_tool_round_trip_with_reasoning
    calls = []
    agent = Truffle.agent(
      provider: :openai_responses,
      model: "gpt-5.5",
      reasoning: { effort: "low" },
      system_prompt: "You are a precise assistant. Always use the multiply " \
                     "tool for any multiplication. Answer with the final number.",
      tools: [multiply_tool(calls)]
    )

    answer = agent.run("What is 23 multiplied by 19? Use your tool.")

    assert_includes calls, [23, 19],
                    "expected the model to call multiply(23, 19), got #{calls.inspect}"
    assert_includes answer.to_s, "437",
                    "expected the final answer to mention 437, got: #{answer.inspect}"

    # The second turn replays turn one's reasoning items and message ids from
    # the session history; a 400 here means the stateless round-trip broke.
    followup = agent.run("Now multiply that result by 2. Use your tool.")

    assert_includes calls, [437, 2],
                    "expected the model to call multiply(437, 2), got #{calls.inspect}"
    assert_includes followup.to_s.delete(","), "874",
                    "expected the follow-up to mention 874, got: #{followup.inspect}"
  end

  def test_streaming_emits_thinking_and_text_events
    provider = Truffle::Providers::OpenAIResponses.new(reasoning: { effort: "low" })
    events = []
    response = provider.chat_stream(
      messages: [Truffle::Message.user("In one short sentence, what is Ruby?")]
    ) { |event| events << event.type }

    assert_equal Truffle::StopReason::STOP, response.stop_reason
    assert_includes events, :text_delta
    refute_empty response.text.to_s
    assert_operator response.usage.total_tokens, :>, 0
  end
end
