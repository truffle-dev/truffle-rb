# frozen_string_literal: true

require_relative "test_helper"

# Tests for the model catalog (Truffle::Models) and the Model value object.
# Two jobs: prove the lookup and value semantics, and guard the catalog against
# silently going stale (a missing current flagship or a malformed entry fails
# here rather than at a user's call site).
class ModelsTest < Minitest::Test
  def test_catalog_is_non_empty_for_both_providers
    refute_empty Truffle::Models.for_provider(:anthropic)
    refute_empty Truffle::Models.for_provider(:openai)
  end

  def test_every_entry_is_well_formed
    Truffle::Models.all.each do |m|
      assert_kind_of Truffle::Model, m
      refute_nil m.name, "#{m.id} missing name"
      assert_operator m.context_window, :>, 0, "#{m.id} context_window"
      assert_operator m.max_output, :>, 0, "#{m.id} max_output"
      %i[input output cache_read cache_write].each do |k|
        assert m.cost.key?(k), "#{m.id} cost missing #{k}"
        assert_operator m.cost[k], :>=, 0, "#{m.id} cost #{k} negative"
      end
    end
  end

  def test_ids_are_unique
    ids = Truffle::Models.all.map(&:id)
    assert_equal ids.uniq, ids
  end

  def test_provider_ids_use_expected_prefixes
    Truffle::Models.for_provider(:anthropic).each do |m|
      assert m.id.start_with?("claude-"), "#{m.id} is not a claude id"
    end
    Truffle::Models.for_provider(:openai).each do |m|
      assert m.id.start_with?("gpt-"), "#{m.id} is not a gpt id"
    end
  end

  # Freshness guard. These are the current flagships as published; if the
  # catalog regresses to an older lineup (the exact failure mode this registry
  # exists to prevent), one of these fails loudly.
  def test_current_flagships_are_present_and_priced
    opus = Truffle::Models.find("claude-opus-4-8")
    assert_equal "Claude Opus 4.8", opus.name
    assert_equal 5.0, opus.cost[:input]
    assert_equal 25.0, opus.cost[:output]
    assert_equal 1_000_000, opus.context_window
    assert opus.reasoning?

    sonnet = Truffle::Models.find("claude-sonnet-4-6")
    assert_equal 3.0, sonnet.cost[:input]
    assert_equal 1_000_000, sonnet.context_window

    haiku = Truffle::Models.find("claude-haiku-4-5")
    assert_equal 1.0, haiku.cost[:input]

    assert Truffle::Models.find("claude-fable-5")
    assert Truffle::Models.find("gpt-5.5")
  end

  def test_one_million_context_models_carry_the_full_window
    %w[claude-fable-5 claude-opus-4-8 claude-opus-4-6 claude-sonnet-4-6 gpt-5.5].each do |id|
      assert_equal 1_000_000, Truffle::Models.find(id).context_window, id
    end
  end

  def test_find_resolves_dated_snapshots_to_their_base_model
    assert_equal Truffle::Models.find("claude-sonnet-4-5"),
                 Truffle::Models.find("claude-sonnet-4-5-20250929")
    assert_equal Truffle::Models.find("claude-haiku-4-5"),
                 Truffle::Models.find("claude-haiku-4-5-20251001")
    assert_equal Truffle::Models.find("gpt-4o"),
                 Truffle::Models.find("gpt-4o-2024-08-06")
  end

  def test_find_returns_nil_for_unknown_and_nil
    assert_nil Truffle::Models.find("no-such-model")
    assert_nil Truffle::Models.find(nil)
  end

  def test_bracket_is_an_alias_for_find
    assert_equal Truffle::Models.find("gpt-4o"), Truffle::Models["gpt-4o"]
  end

  def test_for_provider_filters_and_accepts_strings
    anthropic = Truffle::Models.for_provider("anthropic")
    assert anthropic.all? { |m| m.provider == :anthropic }
    assert_empty Truffle::Models.for_provider(:nonesuch)
  end

  def test_predicates
    assert Truffle::Models.find("claude-opus-4-8").reasoning?
    assert Truffle::Models.find("claude-opus-4-8").vision?
    refute Truffle::Models.find("gpt-4o").reasoning?
    assert Truffle::Models.find("claude-opus-4-1").deprecated?
    refute Truffle::Models.find("claude-opus-4-8").deprecated?
  end

  def test_cost_hash_and_input_list_are_frozen
    m = Truffle::Models.find("gpt-4o")
    assert m.cost.frozen?
    assert m.input.frozen?
    assert_raises(FrozenError) { m.cost[:input] = 0 }
  end

  def test_value_equality
    a = Truffle::Model.new(id: "x", name: "X", provider: :openai,
                           api: :openai_completions, context_window: 1, max_output: 1,
                           cost: { input: 1, output: 1, cache_read: 0, cache_write: 0 })
    b = Truffle::Model.new(id: "x", name: "X", provider: :openai,
                           api: :openai_completions, context_window: 1, max_output: 1,
                           cost: { input: 1, output: 1, cache_read: 0, cache_write: 0 })
    assert_equal a, b
    assert_equal a.hash, b.hash
  end

  # Pricing is now a facade over the catalog; prove they agree and that a dated
  # id prices as its base, since the provider code prices off this path.
  def test_pricing_delegates_to_the_catalog
    assert_equal Truffle::Models.find("claude-opus-4-8").cost,
                 Truffle::Pricing.cost_for("claude-opus-4-8")
    assert_equal Truffle::Pricing.cost_for("gpt-4o"),
                 Truffle::Pricing.cost_for("gpt-4o-2024-08-06")
    assert_nil Truffle::Pricing.cost_for("no-such-model")
    assert_nil Truffle::Pricing.cost_for(nil)
  end
end
