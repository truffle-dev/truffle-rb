# frozen_string_literal: true

module Truffle
  # Per-call token-budget math, ported from pi's simple-options.ts. Two jobs:
  # fit a requested output cap inside the model's remaining context window, and
  # split an output cap into a thinking budget plus room for the visible answer
  # on a reasoning model. Pure and provider-agnostic. A provider option builder
  # calls these when it translates a reasoning level into API parameters, the
  # way pi's Anthropic and Bedrock builders do.
  module TokenBudget
    module_function

    # Headroom pi leaves between the estimated context and the window so a long
    # answer does not overflow the model.
    CONTEXT_SAFETY_TOKENS = 4096

    # A provider call must be allowed at least one output token.
    MIN_MAX_TOKENS = 1

    # The visible-output floor pi keeps when a cap is too small to hold the
    # thinking budget and still leave room for an answer.
    MIN_OUTPUT_TOKENS = 1024

    # Default thinking budget per reasoning level (pi's defaultBudgets). There is
    # no "xhigh" entry because clamp_reasoning folds it to "high" first.
    DEFAULT_THINKING_BUDGETS = {
      "minimal" => 1024,
      "low" => 2048,
      "medium" => 8192,
      "high" => 16_384
    }.freeze

    # Clamp a requested output cap so the answer fits the model's remaining
    # context window. A non-positive window (unknown size) disables the clamp and
    # only enforces the one-token floor. The context estimate is passed in as an
    # integer so this stays provider-agnostic: the caller runs the estimator.
    # Port of clampMaxTokensToContext.
    def clamp_max_tokens_to_context(context_window:, context_tokens:, max_tokens:)
      return [MIN_MAX_TOKENS, max_tokens].max unless context_window.positive?

      available = context_window - context_tokens - CONTEXT_SAFETY_TOKENS
      available.clamp(MIN_MAX_TOKENS, max_tokens)
    end

    # Normalize a reasoning level for a request. pi has no separate "xhigh" API
    # value, so it maps to "high"; every other level (including nil) passes
    # through unchanged. Port of clampReasoning.
    def clamp_reasoning(effort)
      effort == "xhigh" ? "high" : effort
    end

    # Split an output cap into a thinking budget and room for the answer.
    # base_max_tokens nil means the caller set no cap, so use the model cap and
    # fit thinking inside it; otherwise grow the cap by the thinking budget but
    # never past the model cap. When the resulting cap cannot hold the budget
    # plus a visible answer, shrink the budget to whatever is left above the
    # floor, never below zero. reasoning_level is one of the five thinking levels
    # ("minimal", "low", "medium", "high", "xhigh"). Port of
    # adjustMaxTokensForThinking.
    def adjust_max_tokens_for_thinking(base_max_tokens:, model_max_tokens:,
                                       reasoning_level:, custom_budgets: {})
      budgets = DEFAULT_THINKING_BUDGETS.merge(stringify_keys(custom_budgets))
      thinking_budget = budgets[clamp_reasoning(reasoning_level)]

      max_tokens =
        if base_max_tokens.nil?
          model_max_tokens
        else
          [base_max_tokens + thinking_budget, model_max_tokens].min
        end

      thinking_budget = [0, max_tokens - MIN_OUTPUT_TOKENS].max if max_tokens <= thinking_budget

      { max_tokens: max_tokens, thinking_budget: thinking_budget }
    end

    # Fold a caller's custom-budget hash to string keys so a symbol-keyed
    # override still merges over the string-keyed defaults.
    def stringify_keys(budgets)
      budgets.each_with_object({}) { |(key, value), out| out[key.to_s] = value }
    end
  end
end
