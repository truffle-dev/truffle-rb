# frozen_string_literal: true

module Truffle
  # One event in a streamed assistant turn, ported from pi's AssistantMessageEvent
  # union in packages/ai/src/types.ts. A provider's #chat_stream emits these in
  # order so a UI can render a turn as it arrives instead of waiting for the whole
  # message.
  #
  # The sequence for a turn is: one :start, then for each content block a
  # *_start / *_delta* / *_end trio (text, thinking, or toolcall), and finally one
  # terminal event: :done on success or :error on failure. The terminal event
  # carries the complete assistant Message and the StopReason.
  #
  # Field meanings by type:
  #   :start                              partial
  #   :text_start / :thinking_start /
  #     :toolcall_start                   content_index, partial
  #   :text_delta / :thinking_delta       content_index, delta, partial
  #   :toolcall_delta                     content_index, delta, partial
  #   :text_end / :thinking_end           content_index, content, partial
  #   :toolcall_end                       content_index, tool_call, partial
  #   :done                               reason, message
  #   :error                              reason, message, error_message
  #
  # `partial` is the assistant Message built so far, so a consumer can read the
  # whole turn at any point without tracking deltas itself. `content_index` is the
  # block's position in that message's content list. pi spells the terminal
  # message field `error` on the error event; Truffle uses `message` for both
  # terminal events and keeps the human string on `error_message`.
  class StreamEvent
    TYPES = %i[
      start
      text_start text_delta text_end
      thinking_start thinking_delta thinking_end
      toolcall_start toolcall_delta toolcall_end
      done error
    ].freeze

    attr_reader :type, :content_index, :delta, :content, :tool_call,
                :reason, :message, :error_message, :partial

    def initialize(type:, content_index: nil, delta: nil, content: nil,
                   tool_call: nil, reason: nil, message: nil, error_message: nil,
                   partial: nil)
      type = type.to_sym
      unless TYPES.include?(type)
        raise ArgumentError,
              "unknown stream event #{type.inspect}, expected one of #{TYPES.inspect}"
      end

      @type = type
      @content_index = content_index
      @delta = delta
      @content = content
      @tool_call = tool_call
      @reason = reason
      @message = message
      @error_message = error_message
      @partial = partial
    end

    def done?
      @type == :done
    end

    def error?
      @type == :error
    end

    # True for the terminal event of a stream (:done or :error), the point at
    # which `message` and `reason` are final.
    def terminal?
      done? || error?
    end

    def to_h
      {
        type: @type,
        content_index: @content_index,
        delta: @delta,
        content: @content,
        tool_call: @tool_call&.to_h,
        reason: @reason,
        error_message: @error_message
      }.compact
    end
  end
end
