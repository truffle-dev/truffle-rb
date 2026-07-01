# frozen_string_literal: true

require "test_helper"

# Live provider matrix for the highest-risk path in the harness:
# provider streaming -> streamed tool call -> Ruby tool execution -> second
# streamed assistant turn. The default suite stays offline because each case
# skips unless its provider key is present.
class TestLiveStreamingToolMatrix < Minitest::Test
  ProviderCase = Struct.new(:name, :env_key, :provider, :model, keyword_init: true)

  PROVIDERS = [
    ProviderCase.new(name: "openai", env_key: "OPENAI_API_KEY",
                     provider: :openai, model: "gpt-4o-mini"),
    ProviderCase.new(name: "anthropic", env_key: "ANTHROPIC_API_KEY",
                     provider: :anthropic, model: "claude-haiku-4-5"),
    ProviderCase.new(name: "google", env_key: "GEMINI_API_KEY",
                     provider: :google, model: "gemini-2.5-flash-lite")
  ].freeze

  PROVIDERS.each do |entry|
    define_method("test_live_streaming_tool_loop_with_#{entry.name}") do
      skip "set #{entry.env_key} to run the live #{entry.name} streaming tool test" \
        if ENV[entry.env_key].to_s.empty?

      calls = []
      multiply = Truffle::Tool.define(
        "multiply",
        "Multiply two integers. Use this tool for multiplication requests."
      ) do
        param :a, :integer, "first factor", required: true
        param :b, :integer, "second factor", required: true
        run do |a:, b:|
          calls << [a, b]
          a * b
        end
      end
      agent = Truffle.agent(
        provider: entry.provider,
        model: entry.model,
        system_prompt: "You are a precise assistant. For any multiplication, " \
                       "call the multiply tool before answering. After the tool " \
                       "returns, answer with only the final number.",
        tools: [multiply],
        max_turns: 4
      )

      ended = nil
      agent.on(:agent_end) { |payload| ended = payload }
      stream_events = []
      answer = agent.run_stream("Use the multiply tool to calculate 23 * 19.") do |event|
        stream_events << event
      end

      assert_includes calls, [23, 19],
                      "expected #{entry.name} to call multiply(23, 19), got #{calls.inspect}"
      assert stream_events.any? { |event| event.type == :toolcall_end },
             "expected #{entry.name} stream to include a completed tool call"
      assert stream_events.any? { |event| event.type == :text_delta },
             "expected #{entry.name} stream to include final text deltas"
      assert_includes answer.to_s, "437",
                      "expected #{entry.name} final answer to mention 437, got #{answer.inspect}"
      assert_equal Truffle::StopReason::STOP, ended&.fetch(:stop_reason),
                   "expected #{entry.name} agent_end stop reason to be :stop"
    end
  end
end
