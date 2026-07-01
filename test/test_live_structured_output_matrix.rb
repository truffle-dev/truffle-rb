# frozen_string_literal: true

require "test_helper"

# Live provider matrix for Truffle's high-level structured-output path:
# Agent#run_structured -> provider-native schema envelope -> parsed validated
# Ruby value. The default suite stays offline because each case skips unless its
# provider key is present.
class TestLiveStructuredOutputMatrix < Minitest::Test
  ProviderCase = Struct.new(:name, :env_key, :provider, :model, keyword_init: true)

  SCHEMA = {
    type: "object",
    properties: {
      "provider" => { type: "string" },
      "sum" => { type: "integer" },
      "status" => { type: "string" }
    },
    required: %w[provider sum status],
    additionalProperties: false
  }.freeze

  PROVIDERS = [
    ProviderCase.new(name: "openai", env_key: "OPENAI_API_KEY",
                     provider: :openai, model: "gpt-4o-mini"),
    ProviderCase.new(name: "anthropic", env_key: "ANTHROPIC_API_KEY",
                     provider: :anthropic, model: "claude-haiku-4-5"),
    ProviderCase.new(name: "google", env_key: "GEMINI_API_KEY",
                     provider: :google, model: "gemini-2.5-flash-lite")
  ].freeze

  PROVIDERS.each do |entry|
    define_method("test_live_structured_agent_output_with_#{entry.name}") do
      skip "set #{entry.env_key} to run the live #{entry.name} structured output test" \
        if ENV[entry.env_key].to_s.empty?

      agent = Truffle.agent(
        provider: entry.provider,
        model: entry.model,
        system_prompt: "Return the exact data requested by the schema."
      )
      parsed = agent.run_structured(
        "Return provider=#{entry.name.inspect}, sum=42, and status=\"ok\".",
        schema: SCHEMA,
        schema_name: "structured_check",
        strict: true
      )

      assert_equal entry.name, parsed.fetch("provider")
      assert_equal 42, parsed.fetch("sum")
      assert_equal "ok", parsed.fetch("status")
      assert_equal Truffle::StopReason::STOP, agent.last_response.stop_reason
    end
  end
end
