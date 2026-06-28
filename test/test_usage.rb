# frozen_string_literal: true

require "test_helper"

# Unit tests for Truffle::Usage and Truffle::Pricing, the token-accounting and
# cost layer ported from pi's parseChunkUsage / calculateCost, plus the agent's
# cross-turn aggregation. All offline: no provider, no network.
class TestUsage < Minitest::Test
  def test_parse_basic_tokens
    usage = Truffle::Usage.parse({ "prompt_tokens" => 100, "completion_tokens" => 40 })

    assert_equal 100, usage.input
    assert_equal 40, usage.output
    assert_equal 0, usage.cache_read
    assert_equal 140, usage.total_tokens
  end

  def test_parse_handles_nil_and_empty
    assert_equal 0, Truffle::Usage.parse(nil).total_tokens
    assert_equal 0, Truffle::Usage.parse({}).total_tokens
    assert_equal Truffle::Usage.zero, Truffle::Usage.parse({})
  end

  # pi treats cached prompt tokens as a separate read class, and input is the
  # residual: a cached token must not also be billed as fresh input.
  def test_cache_read_is_subtracted_from_input
    usage = Truffle::Usage.parse(
      { "prompt_tokens" => 1000,
        "completion_tokens" => 10,
        "prompt_tokens_details" => { "cached_tokens" => 300 } }
    )

    assert_equal 700, usage.input
    assert_equal 300, usage.cache_read
    assert_equal 1010, usage.total_tokens
  end

  def test_cache_read_falls_back_to_prompt_cache_hit_tokens
    usage = Truffle::Usage.parse({ "prompt_tokens" => 500, "prompt_cache_hit_tokens" => 200 })

    assert_equal 300, usage.input
    assert_equal 200, usage.cache_read
  end

  def test_reasoning_tokens_parsed_as_subset_of_output
    usage = Truffle::Usage.parse(
      { "completion_tokens" => 50,
        "completion_tokens_details" => { "reasoning_tokens" => 30 } }
    )

    assert_equal 50, usage.output
    assert_equal 30, usage.reasoning
  end

  def test_input_never_negative
    usage = Truffle::Usage.parse(
      { "prompt_tokens" => 100,
        "prompt_tokens_details" => { "cached_tokens" => 500 } }
    )

    assert_equal 0, usage.input
  end

  def test_cost_computed_from_pricing
    pricing = Truffle::Pricing.cost_for("gpt-4o-mini")
    usage = Truffle::Usage.parse(
      { "prompt_tokens" => 1_000_000, "completion_tokens" => 1_000_000 },
      pricing: pricing
    )
    # gpt-4o-mini: $0.15/M input, $0.60/M output.
    assert_in_delta 0.15, usage.cost.input, 1e-9
    assert_in_delta 0.6, usage.cost.output, 1e-9
    assert_in_delta 0.75, usage.cost.total, 1e-9
  end

  def test_cache_read_priced_at_its_own_rate
    pricing = Truffle::Pricing.cost_for("gpt-4o-mini")
    usage = Truffle::Usage.parse(
      { "prompt_tokens" => 1_000_000,
        "prompt_tokens_details" => { "cached_tokens" => 1_000_000 } },
      pricing: pricing
    )
    # All cached: zero input cost, cache_read billed at $0.075/M.
    assert_in_delta 0.0, usage.cost.input, 1e-9
    assert_in_delta 0.075, usage.cost.cache_read, 1e-9
    assert_in_delta 0.075, usage.cost.total, 1e-9
  end

  def test_without_pricing_cost_is_zero
    usage = Truffle::Usage.parse({ "prompt_tokens" => 1_000_000, "completion_tokens" => 1_000_000 })

    assert_in_delta 0.0, usage.cost.total, 1e-9
  end

  def test_addition_sums_tokens_and_cost
    pricing = Truffle::Pricing.cost_for("gpt-4o")
    a = Truffle::Usage.parse({ "prompt_tokens" => 100, "completion_tokens" => 20 },
                             pricing: pricing)
    b = Truffle::Usage.parse({ "prompt_tokens" => 300, "completion_tokens" => 80 },
                             pricing: pricing)
    sum = a + b

    assert_equal 400, sum.input
    assert_equal 100, sum.output
    assert_equal 500, sum.total_tokens
    assert_in_delta a.cost.total + b.cost.total, sum.cost.total, 1e-12
  end

  def test_zero_is_addition_identity
    usage = Truffle::Usage.parse({ "prompt_tokens" => 42, "completion_tokens" => 7 })

    assert_equal usage, Truffle::Usage.zero + usage
    assert_equal usage, usage + Truffle::Usage.zero
  end

  def test_pricing_strips_date_snapshot_suffix
    assert_equal Truffle::Pricing.cost_for("gpt-4o"),
                 Truffle::Pricing.cost_for("gpt-4o-2024-08-06")
  end

  def test_pricing_unknown_model_is_nil
    assert_nil Truffle::Pricing.cost_for("some-model-we-do-not-know")
    assert_nil Truffle::Pricing.cost_for(nil)
  end

  def test_unknown_model_usage_still_counts_tokens
    usage = Truffle::Usage.parse(
      { "prompt_tokens" => 10, "completion_tokens" => 5 },
      pricing: Truffle::Pricing.cost_for("unknown")
    )

    assert_equal 15, usage.total_tokens
    assert_in_delta 0.0, usage.cost.total, 1e-9
  end

  def test_to_h_shape
    usage = Truffle::Usage.parse({ "prompt_tokens" => 3, "completion_tokens" => 1 })
    h = usage.to_h

    assert_equal 3, h[:input]
    assert_equal 1, h[:output]
    assert_equal 4, h[:total_tokens]
    assert_kind_of Hash, h[:cost]
  end
end

# The agent tallies usage and cost across every turn of a run and reports the
# running total on agent_end.
class TestAgentUsage < Minitest::Test
  def usage_for(input:, output:, model: "gpt-4o-mini")
    Truffle::Usage.parse(
      { "prompt_tokens" => input, "completion_tokens" => output },
      pricing: Truffle::Pricing.cost_for(model)
    )
  end

  def test_usage_accumulates_across_turns
    echo = Truffle::Tool.define("echo", "echo back") do
      param :value, :string, required: true
      run { |value:| value }
    end

    provider = StubProvider.new(
      [
        StubProvider.tool_call(id: "1", name: "echo", arguments: { "value" => "hi" },
                               usage: usage_for(input: 100, output: 10)),
        StubProvider.text("done", usage: usage_for(input: 200, output: 20))
      ]
    )

    seen = nil
    agent = Truffle.agent(provider: provider, tools: [echo])
    agent.on(:agent_end) { |p| seen = p[:usage] }
    agent.run("go")

    assert_equal 300, agent.usage.input
    assert_equal 30, agent.usage.output
    assert_equal 330, agent.usage.total_tokens
    assert_equal agent.usage, seen
    assert_operator agent.usage.cost.total, :>, 0.0
  end

  def test_reset_clears_usage
    provider = StubProvider.new([StubProvider.text("ok", usage: usage_for(input: 50, output: 5))])
    agent = Truffle.agent(provider: provider)
    agent.run("hi")

    refute_equal 0, agent.usage.total_tokens

    agent.reset

    assert_equal Truffle::Usage.zero, agent.usage
  end
end
