# frozen_string_literal: true

require "time"
require_relative "../json_repair"
require_relative "../unicode_sanitizer"

module Truffle
  module Providers
    # Normalize a `schema:` option into the provider-neutral JSON-schema hash that
    # each provider wraps in its own structured-output envelope. The option is a
    # Truffle::Schema (whose #to_h is the frozen definition) or a plain Hash; both
    # answer #to_h, so this is the single coercion every provider shares. Defined
    # at module level so the instance-method builder (OpenAI) and the class-method
    # builders (Anthropic, Google) can all reach it.
    def self.schema_definition(schema)
      schema.respond_to?(:to_h) ? schema.to_h : schema
    end

    # Provider request bodies can reject or fail to encode text containing lone
    # surrogate byte sequences. Keep sanitization at the provider boundary so the
    # in-memory transcript remains unchanged while every outbound text field is
    # JSON-safe.
    def self.sanitize_text(text)
      return text if text.nil?

      UnicodeSanitizer.sanitize_surrogates(text.to_s)
    end

    # Final tool-call arguments should be a parsed Ruby object by the time they
    # leave a provider. Most providers already return a Hash. OpenAI-compatible
    # providers return a JSON string, and models can occasionally emit malformed
    # string literals; repair those completed payloads before falling back to a
    # raw sentinel.
    def self.parse_tool_arguments(raw)
      return {} if raw.nil?
      return raw unless raw.is_a?(String)
      return {} if raw.empty?

      JsonRepair.parse(raw)
    rescue JSON::ParserError
      { "_raw" => raw }
    end

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
      def error_response(message, model: nil, retry_after_ms: nil)
        Response.new(
          message: Message.assistant(content: nil),
          stop_reason: StopReason::ERROR,
          error_message: message,
          model: model,
          retry_after_ms: retry_after_ms
        )
      end

      def retry_after_ms(response)
        millis = numeric_header(response["retry-after-ms"])
        return [millis, 0].max.to_i if millis

        retry_after = response["retry-after"]
        return nil if retry_after.nil? || retry_after.empty?

        seconds = numeric_header(retry_after)
        return [seconds * 1000, 0].max.to_i if seconds

        date = Time.httpdate(retry_after)
        [((date - Time.now) * 1000).ceil, 0].max
      rescue ArgumentError
        nil
      end

      def numeric_header(value)
        number = Float(value, exception: false)
        number&.finite? ? number : nil
      end
    end

    # Raised inside a provider when an HTTP call fails, a payload will not parse,
    # or the transport faults. #chat folds it into an error turn; callers of the
    # private transport (#post) still see it as a raise.
    class Error < StandardError
      attr_reader :retry_after_ms

      def initialize(message = nil, retry_after_ms: nil)
        super(message)
        @retry_after_ms = retry_after_ms
      end
    end
  end
end
