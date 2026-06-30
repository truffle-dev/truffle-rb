# frozen_string_literal: true

module Truffle
  module Providers
    # The contract every provider implements. This single seam is what makes
    # Truffle provider-agnostic: the agent loop only ever calls #chat and reads a
    # Truffle::Response back. Swapping OpenAI for Anthropic or a local model is a
    # one-line change at construction time. Every provider is written from
    # scratch against this seam; there are no runtime gem dependencies.
    #
    # Subclasses must implement #chat. They are free to translate Truffle::Message
    # objects and tool schemas into their native wire format however they like.
    class Base
      # @param messages [Array<Truffle::Message>] the conversation so far
      # @param tools [Array<Hash>] provider-neutral tool schemas (Toolbox#to_schema)
      # @param model [String, nil] override the default model for this call
      # @return [Truffle::Response]
      def chat(messages:, tools: [], model: nil, **options)
        raise NotImplementedError, "#{self.class} must implement #chat"
      end

      # Streaming counterpart to #chat. Yields Truffle::StreamEvent objects in
      # order as the turn arrives and returns the final Truffle::Response. A
      # provider that has no native streaming may leave this unimplemented; the
      # agent loop uses #chat unless a caller opts into streaming explicitly.
      #
      # @yieldparam event [Truffle::StreamEvent]
      # @return [Truffle::Response]
      def chat_stream(messages:, tools: [], model: nil, **options)
        raise NotImplementedError, "#{self.class} must implement #chat_stream"
      end

      # Human-readable provider id, used in events and errors.
      def name
        self.class.name.split("::").last.downcase
      end

      protected

      # The error turn a failed #chat returns instead of raising. pi never throws
      # out of a provider: a failed call surfaces as a turn whose stop_reason is
      # :error carrying the failure text, so the agent loop can read it (retry,
      # compact on a context overflow, or end with the message). The streaming
      # paths already fold their failures this way through the accumulator's
      # #fail; this is the same shape for the non-streaming call. The message is
      # empty and usage is zero, since a failed call produced no content.
      def error_response(message, model: nil)
        Response.new(
          message: Message.assistant(content: nil),
          stop_reason: StopReason::ERROR,
          error_message: message,
          model: model
        )
      end
    end

    # Raised inside a provider when an HTTP call fails, a payload will not parse,
    # or the transport faults. #chat folds it into an error turn; callers of the
    # private transport (#post) still see it as a raise.
    class Error < StandardError; end
  end
end
