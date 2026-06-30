# frozen_string_literal: true

require "json"

module Truffle
  # A normalized response from a provider's chat call.
  #
  # Every provider returns one of these regardless of its native wire format, so
  # the agent loop never has to branch on which model it is talking to.
  class Response
    UNPARSED = Object.new.freeze

    attr_reader :message, :usage, :raw, :model, :finish_reason, :stop_reason,
                :error_message, :retry_after_ms

    def initialize(message:, usage: nil, raw: nil, model: nil, finish_reason: nil,
                   stop_reason: nil, error_message: nil, retry_after_ms: nil)
      @message = message
      # usage is a Truffle::Usage (token counts plus dollar cost). An empty turn
      # gets a zero usage so callers can always read .usage.total_tokens.
      @usage = usage || Usage.zero
      @raw = raw
      @model = model
      # finish_reason is the provider's raw string (kept for debugging); stop_reason
      # is the normalized Truffle::StopReason the provider mapped it to.
      @finish_reason = finish_reason
      @stop_reason = stop_reason
      @error_message = error_message
      @retry_after_ms = retry_after_ms
      @parsed = UNPARSED
    end

    # The text content of the assistant turn (may be nil on a pure tool call).
    def text
      message.text
    end

    def tool_calls
      message.tool_calls
    end

    def tool_calls?
      message.tool_calls?
    end

    # Parse the final assistant text as JSON and memoize the result. The text is
    # parsed exactly as returned by the provider; callers that want repair,
    # retries, or schema-invalid recovery can layer that policy outside Response.
    def parsed
      return @parsed unless @parsed.equal?(UNPARSED)

      @parsed = JSON.parse(text || "")
    end
  end
end
