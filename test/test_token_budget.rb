# frozen_string_literal: true

require_relative "test_helper"

# Covers Truffle::TokenBudget, the per-call token-budget math ported from pi's
# simple-options.ts: fitting an output cap inside a context window, folding a
# reasoning level, and splitting a cap into a thinking budget plus visible room.
class TestTokenBudget < Minitest::Test
  def test_clamp_returns_max_tokens_floor_when_window_unknown
    # A non-positive window disables the clamp and only enforces the one-token
    # floor, so a generous cap passes straight through.
    assert_equal 5000,
                 Truffle::TokenBudget.clamp_max_tokens_to_context(
                   context_window: 0, context_tokens: 999, max_tokens: 5000
                 )
  end

  def test_clamp_enforces_one_token_floor_when_window_unknown
    assert_equal 1,
                 Truffle::TokenBudget.clamp_max_tokens_to_context(
                   context_window: -1, context_tokens: 0, max_tokens: 0
                 )
  end

  def test_clamp_leaves_cap_alone_when_it_fits
    # window 100_000, used 10_000, safety 4096 leaves 85_904 available, so a
    # 2000 cap is untouched.
    assert_equal 2000,
                 Truffle::TokenBudget.clamp_max_tokens_to_context(
                   context_window: 100_000, context_tokens: 10_000, max_tokens: 2000
                 )
  end

  def test_clamp_shrinks_cap_to_available_room
    # window 20_000, used 15_000, safety 4096 leaves 904 available, so a 2000
    # cap is clamped down to 904.
    assert_equal 904,
                 Truffle::TokenBudget.clamp_max_tokens_to_context(
                   context_window: 20_000, context_tokens: 15_000, max_tokens: 2000
                 )
  end

  def test_clamp_never_returns_below_one_token
    # available goes negative here; the floor keeps the result at one token.
    assert_equal 1,
                 Truffle::TokenBudget.clamp_max_tokens_to_context(
                   context_window: 5000, context_tokens: 5000, max_tokens: 2000
                 )
  end

  def test_clamp_reasoning_folds_xhigh_to_high
    assert_equal "high", Truffle::TokenBudget.clamp_reasoning("xhigh")
  end

  def test_clamp_reasoning_passes_other_levels_through
    %w[minimal low medium high].each do |level|
      assert_equal level, Truffle::TokenBudget.clamp_reasoning(level)
    end
    assert_nil Truffle::TokenBudget.clamp_reasoning(nil)
  end

  def test_adjust_uses_model_cap_when_base_is_nil
    # A nil base means the caller set no cap, so the model cap is used and the
    # thinking budget fits inside it.
    result = Truffle::TokenBudget.adjust_max_tokens_for_thinking(
      base_max_tokens: nil, model_max_tokens: 64_000, reasoning_level: "medium"
    )

    assert_equal({ max_tokens: 64_000, thinking_budget: 8192 }, result)
  end

  def test_adjust_grows_base_by_budget_but_caps_at_model
    # base 4000 + medium budget 8192 = 12_192, under the 64_000 model cap.
    result = Truffle::TokenBudget.adjust_max_tokens_for_thinking(
      base_max_tokens: 4000, model_max_tokens: 64_000, reasoning_level: "medium"
    )

    assert_equal({ max_tokens: 12_192, thinking_budget: 8192 }, result)
  end

  def test_adjust_never_grows_past_model_cap
    # base 60_000 + high budget 16_384 = 76_384, clamped to the 64_000 cap.
    result = Truffle::TokenBudget.adjust_max_tokens_for_thinking(
      base_max_tokens: 60_000, model_max_tokens: 64_000, reasoning_level: "high"
    )

    assert_equal 64_000, result[:max_tokens]
  end

  def test_adjust_shrinks_budget_to_leave_visible_room
    # cap 8192 cannot hold the high budget 16_384 plus a visible answer, so the
    # budget shrinks to cap minus the 1024 visible floor.
    result = Truffle::TokenBudget.adjust_max_tokens_for_thinking(
      base_max_tokens: nil, model_max_tokens: 8192, reasoning_level: "high"
    )

    assert_equal({ max_tokens: 8192, thinking_budget: 7168 }, result)
  end

  def test_adjust_never_shrinks_budget_below_zero
    # cap 512 is under the visible floor, so the budget floors at zero rather
    # than going negative.
    result = Truffle::TokenBudget.adjust_max_tokens_for_thinking(
      base_max_tokens: nil, model_max_tokens: 512, reasoning_level: "high"
    )

    assert_equal({ max_tokens: 512, thinking_budget: 0 }, result)
  end

  def test_adjust_folds_xhigh_to_high_budget
    # xhigh has no budget of its own; it folds to high's 16_384.
    result = Truffle::TokenBudget.adjust_max_tokens_for_thinking(
      base_max_tokens: nil, model_max_tokens: 64_000, reasoning_level: "xhigh"
    )

    assert_equal 16_384, result[:thinking_budget]
  end

  def test_adjust_uses_default_budget_for_each_level
    {
      "minimal" => 1024,
      "low" => 2048,
      "medium" => 8192,
      "high" => 16_384
    }.each do |level, budget|
      result = Truffle::TokenBudget.adjust_max_tokens_for_thinking(
        base_max_tokens: nil, model_max_tokens: 64_000, reasoning_level: level
      )

      assert_equal budget, result[:thinking_budget], "level #{level}"
    end
  end

  def test_adjust_custom_budgets_override_defaults
    result = Truffle::TokenBudget.adjust_max_tokens_for_thinking(
      base_max_tokens: nil, model_max_tokens: 64_000, reasoning_level: "low",
      custom_budgets: { "low" => 3000 }
    )

    assert_equal 3000, result[:thinking_budget]
  end

  def test_adjust_custom_budgets_accept_symbol_keys
    # A symbol-keyed override still merges over the string-keyed defaults.
    result = Truffle::TokenBudget.adjust_max_tokens_for_thinking(
      base_max_tokens: nil, model_max_tokens: 64_000, reasoning_level: "medium",
      custom_budgets: { medium: 5000 }
    )

    assert_equal 5000, result[:thinking_budget]
  end
end
