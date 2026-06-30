# frozen_string_literal: true

require "test_helper"

# Retry.retryable_assistant_error? classifies whether a failed turn reads as a
# transient provider or transport error worth restarting. Mirrors pi's
# packages/ai/test/retry.test.ts, with one assertion per pattern family so a
# broken regex names the wording it broke.
class TestRetry < Minitest::Test
  include Truffle

  def error_response(message)
    Response.new(message: Message.assistant(content: []), usage: Usage.zero,
                 stop_reason: StopReason::ERROR, error_message: message)
  end

  def retryable?(message)
    Retry.retryable_assistant_error?(error_response(message))
  end

  # Explicit provider retry guidance (pi's openAIExplicitRetryMessage and
  # bedrockExplicitRetryMessage).
  def test_matches_openai_explicit_retry_guidance
    assert retryable?(
      "An error occurred while processing your request. You can retry your request, " \
      "or contact us through our help center at help.openai.com if the error persists."
    )
  end

  def test_matches_bedrock_explicit_retry_guidance
    assert retryable?(
      '{"message":"The system encountered an unexpected error during processing. ' \
      'Try your request again."}'
    )
  end

  # Provider load and HTTP transient status families.
  def test_matches_overloaded
    assert retryable?("overloaded_error")
  end

  def test_matches_rate_limit
    assert retryable?("Rate limit reached, slow down")
  end

  def test_matches_http_5xx
    assert retryable?("503 Service Unavailable")
  end

  def test_matches_openrouter_provider_returned_error
    assert retryable?("Provider returned error")
  end

  # Network and transport failures.
  def test_matches_socket_hang_up
    assert retryable?("socket hang up")
  end

  def test_matches_upstream_connect
    assert retryable?("upstream connect error or disconnect/reset before headers")
  end

  def test_matches_timeout
    assert retryable?("Request timed out after 60s")
  end

  # Premature stream endings.
  def test_matches_stream_ended_before_message_stop
    assert retryable?("Anthropic stream ended before message_stop")
  end

  def test_matches_http2_no_response
    assert retryable?("http2 request did not get a response")
  end

  # An account or billing limit is not retryable even when it also reads like a
  # throttle. "429 quota exceeded" matches the retryable 429 pattern, but the
  # non-retryable "quota exceeded" pattern wins. This is the precedence guard.
  def test_account_limit_beats_a_matching_retryable_pattern
    refute retryable?("429 quota exceeded")
  end

  def test_keeps_insufficient_quota_non_retryable
    assert_match(/insufficient_quota/, "Error: insufficient_quota")
    refute retryable?("You exceeded your current quota: insufficient_quota")
  end

  def test_keeps_billing_non_retryable
    refute retryable?("billing hard limit reached")
  end

  def test_keeps_opencode_usage_limit_non_retryable
    refute retryable?('{"type":"GoUsageLimitError","message":"Monthly usage limit reached"}')
  end

  # Only an error turn qualifies. A turn whose stop reason is not ERROR is never
  # retryable, even if it somehow carries text that reads like a transient error:
  # a finished answer is not a failed call.
  def test_a_non_error_turn_is_not_retryable
    response = Response.new(message: Message.assistant(content: []),
                            stop_reason: StopReason::STOP, error_message: "503 overloaded")

    refute Retry.retryable_assistant_error?(response)
  end

  def test_an_error_turn_with_no_message_is_not_retryable
    response = Response.new(message: Message.assistant(content: []),
                            stop_reason: StopReason::ERROR, error_message: nil)

    refute Retry.retryable_assistant_error?(response)
  end

  def test_an_error_turn_with_an_empty_message_is_not_retryable
    refute retryable?("")
  end

  # An error message that matches nothing is left non-retryable rather than
  # guessed retryable.
  def test_an_unrecognized_error_is_not_retryable
    refute retryable?("the model declined to answer for policy reasons")
  end

  # The exposed pattern lists are copies: mutating them cannot corrupt the source.
  def test_pattern_accessors_return_copies
    Retry.retryable_patterns.clear
    Retry.non_retryable_patterns.clear

    assert retryable?("overloaded_error")
    refute retryable?("quota exceeded")
  end
end
