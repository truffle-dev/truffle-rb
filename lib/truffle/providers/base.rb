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
    end

    # Raised when a provider's HTTP call fails or returns an error payload.
    class Error < StandardError; end
  end
end
