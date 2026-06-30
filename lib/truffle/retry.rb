# frozen_string_literal: true

require_relative "stop_reason"

module Truffle
  # Classifying whether a failed turn looks like a transient provider or transport
  # error, so a caller can decide to restart the last assistant turn. This is the
  # companion to Overflow: overflow means the prompt was too big (compact and
  # retry), a retryable error means the call itself faltered (a load spike, a
  # throttle, a dropped socket) and the same request may succeed if tried again.
  # A faithful port of pi's packages/ai/src/utils/retry.ts.
  #
  # This is classification, not policy. It decides only whether an error reads as
  # transient. A caller still owns context-overflow handling (check that first),
  # the retry budget, the backoff, and the reporting before restarting a turn.
  module Retry
    # Phrases that look transient but are really an account or billing limit: a
    # spent quota or budget will not recover on a retry, so a message matching one
    # of these is never retryable even when it also matches a retryable pattern (a
    # "429 quota exceeded" is a quota error, not a throttle). Ported verbatim from
    # pi's NON_RETRYABLE_PROVIDER_LIMIT_ERROR_PATTERN. Checked before the retryable
    # list so it wins ties.
    NON_RETRYABLE_PATTERNS = [
      # OpenCode Zen API free/subscription limits returned as 429 JSON error types.
      # These are account limits, not transient throttles.
      /GoUsageLimitError/i,
      /FreeUsageLimitError/i,
      /Monthly usage limit reached/i,
      /available balance/i,
      # Generic quota, budget, and billing exhaustion. insufficient_quota is
      # OpenAI's billing error code; the rest cover common gateway wording.
      /insufficient_quota/i,
      /out of budget/i,
      /quota exceeded/i,
      /billing/i
    ].freeze

    # Phrases that mean the call faltered in a way a retry can recover from: a
    # provider load spike, an HTTP 5xx, a throttle, a network or stream transport
    # failure, or explicit provider guidance to retry. Each entry carries the
    # provider, transport, or pi issue it came from so a future reader adds the
    # next one from a real error string rather than a guess. Ported verbatim from
    # pi's RETRYABLE_PROVIDER_ERROR_PATTERN.
    RETRYABLE_PATTERNS = [
      # Provider load, HTTP status, and server-side transient failures.
      /overloaded/i,
      /rate.?limit/i,
      /too many requests/i,
      /429/i,
      /500/i,
      /502/i,
      /503/i,
      /504/i,
      /service.?unavailable/i,
      /server.?error/i,
      /internal.?error/i,
      # OpenRouter "Provider returned error" wrapper responses (#2264).
      /provider.?returned.?error/i,
      # Network, proxy, and fetch transport failures, including OpenAI Codex
      # raw-fetch failures (#733) and OpenRouter connection drops (#3317).
      /network.?error/i,
      /connection.?error/i,
      /connection.?refused/i,
      /connection.?lost/i,
      /other side closed/i,
      /fetch failed/i,
      /upstream.?connect/i,
      /reset before headers/i,
      /socket hang up/i,
      /timed? out/i,
      /timeout/i,
      /terminated/i,
      # WebSocket transports report close/error text instead of HTTP/fetch text.
      /websocket.?closed/i,
      /websocket.?error/i,
      # Premature stream endings: Anthropic "stream ended before message_stop"
      # (#4433) and Bedrock/Smithy HTTP/2 no-response (#3594).
      /ended without/i,
      /stream ended before message_stop/i,
      /http2 request did not get a response/i,
      # Provider-requested retry-delay failures flow through the retry policy so a
      # caller can surface or abort the backoff (#1123).
      /retry delay/i,
      # Explicit retry guidance from OpenAI Responses and Bedrock stream
      # exceptions (#6019).
      /you can retry your request/i,
      /try your request again/i,
      /please retry your request/i
    ].freeze

    module_function

    # Whether a failed turn reads as a transient, retryable error. Only an error
    # turn qualifies: response.stop_reason must be ERROR and it must carry an
    # error_message (a successful or empty turn is never retryable). A message that
    # matches a non-retryable account or billing limit is rejected even if it also
    # matches a retryable pattern. response is this port's analog of pi's
    # AssistantMessage, bundling the same stop_reason and error_message. Port of
    # pi's isRetryableAssistantError.
    def retryable_assistant_error?(response)
      return false unless response.stop_reason == StopReason::ERROR

      message = response.error_message
      return false if message.nil? || message.empty?
      return false if NON_RETRYABLE_PATTERNS.any? { |pattern| pattern.match?(message) }

      RETRYABLE_PATTERNS.any? { |pattern| pattern.match?(message) }
    end

    # The retryable patterns, copied so a caller or test cannot mutate the frozen
    # source list.
    def retryable_patterns
      RETRYABLE_PATTERNS.dup
    end

    # The non-retryable account/limit patterns, copied for the same reason.
    def non_retryable_patterns
      NON_RETRYABLE_PATTERNS.dup
    end
  end
end
