# frozen_string_literal: true

require "test_helper"

# End-to-end test against the real Anthropic Messages API. Skipped unless
# ANTHROPIC_API_KEY is set, so the default `rake test` stays hermetic and
# offline. Run it with a key present to verify the full round-trip: prompt ->
# model requests a tool -> Truffle runs it -> model answers with the result.
class TestAnthropicIntegration < Minitest::Test
  def setup
    skip "set ANTHROPIC_API_KEY to run the live Anthropic test" if ENV["ANTHROPIC_API_KEY"].to_s.empty?
  end

  def test_tool_round_trip_with_real_model
    calls = []
    multiply = Truffle::Tool.define("multiply", "Multiply two integers together") do
      param :a, :integer, "first factor", required: true
      param :b, :integer, "second factor", required: true
      run do |a:, b:|
        calls << [a, b]
        a * b
      end
    end

    agent = Truffle.agent(
      provider: :anthropic,
      model: "claude-sonnet-4-5",
      system_prompt: "You are a precise assistant. Always use the multiply tool for any multiplication. Answer with the final number.",
      tools: [multiply]
    )

    answer = agent.run("What is 23 multiplied by 19? Use your tool.")

    # The model must have actually invoked our tool with the right operands.
    assert_includes calls, [23, 19], "expected the model to call multiply(23, 19), got #{calls.inspect}"
    # And the final answer must contain the product.
    assert_includes answer.to_s, "437", "expected the final answer to mention 437, got: #{answer.inspect}"
  end
end
