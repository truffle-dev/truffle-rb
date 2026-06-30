# frozen_string_literal: true

require "test_helper"

# Overflow.context_overflow? recognizes a turn that failed (or silently
# degraded) because the prompt exceeded the model's context window, across the
# three ways providers report it: a matching error phrase, a successful turn
# whose input already exceeds the window, and a length stop that produced no
# output with the window full. Mirrors pi's packages/ai/test/overflow.test.ts.
class TestOverflow < Minitest::Test
  include Truffle

  def error_response(message)
    Response.new(message: Message.assistant(content: []), usage: Usage.zero,
                 stop_reason: StopReason::ERROR, error_message: message)
  end

  def usage_response(stop_reason, input:, cache_read: 0, output: 0)
    Response.new(
      message: Message.assistant(content: []),
      usage: Usage.new(input: input, cache_read: cache_read, output: output),
      stop_reason: stop_reason
    )
  end

  # Case 1: error-phrase detection, one assertion per provider wording so a
  # broken regex names the provider it broke.
  def test_detects_anthropic_prompt_too_long
    assert overflow?("prompt is too long: 213462 tokens > 200000 maximum")
  end

  def test_detects_anthropic_request_too_large
    assert overflow?(
      '413 {"error":{"type":"request_too_large","message":"Request exceeds the maximum size"}}'
    )
  end

  def test_detects_openai_exceeds_context_window
    assert overflow?("Your input exceeds the context window of this model")
  end

  def test_detects_litellm_wrapped_maximum_context_length
    assert overflow?(
      "Error: 503 litellm.APIConnectionError: OpenAIException - Requested token count " \
      "exceeds the model's maximum context length of 131072 tokens."
    )
  end

  def test_detects_parenthesized_maximum_context_length
    assert overflow?(
      "Error: 400 Input length (265330) exceeds model's maximum context length (262144)."
    )
  end

  def test_detects_google_input_token_count
    assert overflow?(
      "The input token count (1196265) exceeds the maximum number of tokens allowed (1048575)"
    )
  end

  def test_detects_xai_maximum_prompt_length
    assert overflow?(
      "This model's maximum prompt length is 131072 but the request contains 537812 tokens"
    )
  end

  def test_detects_groq_reduce_the_length
    assert overflow?("Please reduce the length of the messages or completion")
  end

  def test_detects_openrouter_maximum_context_length
    assert overflow?(
      "This endpoint's maximum context length is 131072 tokens. " \
      "However, you requested about 200000 tokens"
    )
  end

  def test_detects_poolside_maximum_allowed_input_length
    assert overflow?(
      "Input length 131393 exceeds the maximum allowed input length of 131040 tokens."
    )
  end

  def test_detects_together_ai_input_longer_than_context_length
    assert overflow?(
      "400 The input (516368 tokens) is longer than the model's context length (262144 tokens)."
    )
  end

  def test_detects_github_copilot_exceeds_the_limit
    assert overflow?("prompt token count of 200000 exceeds the limit of 128000")
  end

  def test_detects_llama_cpp_available_context_size
    assert overflow?("the request exceeds the available context size, try increasing it")
  end

  def test_detects_lm_studio_greater_than_context_length
    assert overflow?("tokens to keep from the initial prompt is greater than the context length")
  end

  def test_detects_minimax_context_window_exceeds_limit
    assert overflow?("invalid params, context window exceeds limit")
  end

  def test_detects_kimi_exceeded_model_token_limit
    assert overflow?("Your request exceeded model token limit: 256000 (requested: 300000)")
  end

  def test_detects_mistral_too_large_for_model
    assert overflow?(
      "Prompt contains 200000 tokens, too large for model with 131072 maximum context length"
    )
  end

  def test_detects_ollama_prompt_too_long
    assert overflow?("400 `prompt too long; exceeded max context length by 100918 tokens`")
  end

  def test_detects_cerebras_status_code_no_body
    assert overflow?("413 status code (no body)")
  end

  def test_detects_generic_fallbacks
    assert overflow?("context_length_exceeded")
    assert overflow?("token limit exceeded")
  end

  # The exclusion list keeps throttling and rate-limit errors out, even when they
  # contain a phrase ("too many tokens") that an overflow pattern also matches.
  def test_excludes_bedrock_throttling_too_many_tokens
    refute overflow?("Throttling error: Too many tokens, please wait before trying again.")
  end

  def test_excludes_bedrock_service_unavailable
    refute overflow?("Service unavailable: The service is temporarily unavailable.")
  end

  def test_excludes_generic_rate_limit
    refute overflow?("Rate limit exceeded, please retry after 30 seconds.")
  end

  def test_excludes_http_429_too_many_requests
    refute overflow?("Too many requests. Please slow down.")
  end

  def test_excludes_unrelated_runner_crash
    refute overflow?("500 `model runner crashed unexpectedly`")
  end

  def test_error_turn_with_no_message_is_not_overflow
    refute Overflow.context_overflow?(
      Response.new(message: Message.assistant(content: []), stop_reason: StopReason::ERROR),
      context_window: 200_000
    )
  end

  # Case 2: a successful turn whose input already exceeds the window (z.ai).
  def test_detects_silent_overflow_on_stop
    response = usage_response(StopReason::STOP, input: 201_000)

    assert Overflow.context_overflow?(response, context_window: 200_000)
  end

  def test_silent_overflow_counts_cache_read_toward_input
    response = usage_response(StopReason::STOP, input: 100_000, cache_read: 101_000)

    assert Overflow.context_overflow?(response, context_window: 200_000)
  end

  def test_stop_within_window_is_not_overflow
    response = usage_response(StopReason::STOP, input: 150_000)

    refute Overflow.context_overflow?(response, context_window: 200_000)
  end

  def test_silent_overflow_requires_a_window
    response = usage_response(StopReason::STOP, input: 201_000)

    refute Overflow.context_overflow?(response)
  end

  # Case 3: a length stop with zero output and the window all but full (Xiaomi).
  def test_detects_length_stop_overflow
    response = usage_response(StopReason::LENGTH, input: 58, cache_read: 1_048_512, output: 0)

    assert Overflow.context_overflow?(response, context_window: 1_048_576)
  end

  def test_length_stop_with_output_is_not_overflow
    response = usage_response(StopReason::LENGTH, input: 1_000, output: 4_096)

    refute Overflow.context_overflow?(response, context_window: 200_000)
  end

  def test_length_stop_far_below_window_is_not_overflow
    response = usage_response(StopReason::LENGTH, input: 100, output: 0)

    refute Overflow.context_overflow?(response, context_window: 200_000)
  end

  def test_patterns_returns_a_safe_copy
    copy = Overflow.patterns
    copy << /mutated/

    refute_includes Overflow::OVERFLOW_PATTERNS, /mutated/
  end

  private

  def overflow?(message, context_window: 200_000)
    Overflow.context_overflow?(error_response(message), context_window: context_window)
  end
end
