# frozen_string_literal: true

module Truffle
  # A normalized response from a provider's chat call.
  #
  # Every provider returns one of these regardless of its native wire format, so
  # the agent loop never has to branch on which model it is talking to.
  class Response
    attr_reader :message, :usage, :raw, :model, :finish_reason

    def initialize(message:, usage: {}, raw: nil, model: nil, finish_reason: nil)
      @message = message
      @usage = usage || {}
      @raw = raw
      @model = model
      @finish_reason = finish_reason
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
  end
end
