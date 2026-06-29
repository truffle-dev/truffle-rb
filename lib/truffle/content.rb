# frozen_string_literal: true

module Truffle
  # Typed content blocks. A message's content is a list of these, not a single
  # string, which is how pi models content: text and thinking on assistant turns,
  # text and images on user and tool-result turns. Tool calls are blocks too and
  # live in Truffle::ToolCall (see message.rb).
  #
  # Each block answers #type with a symbol and #to_h with a plain Hash, so a
  # history round-trips through JSON without the agent loop knowing block shapes.
  module Content
    module_function

    # Rebuild a typed block from the Hash that #to_h produced, the inverse used
    # when a session is read back from disk. Keys may be symbols (a direct #to_h)
    # or strings (after a JSON round-trip), so they are folded to strings first.
    # A "tool_call" block rebuilds a Truffle::ToolCall, which lives in the same
    # list as the content blocks (see message.rb).
    def from_h(hash)
      h = hash.transform_keys(&:to_s)
      case h["type"].to_s
      when "text"
        Text.new(text: h["text"], signature: h["signature"])
      when "thinking"
        Thinking.new(thinking: h["thinking"], signature: h["signature"],
                     redacted: h.fetch("redacted", false))
      when "image"
        Image.new(data: h["data"], mime_type: h["mime_type"])
      when "tool_call"
        ToolCall.new(id: h["id"], name: h["name"], arguments: h["arguments"])
      else
        raise ArgumentError, "unknown content block type #{h["type"].inspect}"
      end
    end

    # A run of assistant or user text. `signature` carries opaque provider
    # metadata (for example an OpenAI responses message id) when one is present.
    class Text
      attr_reader :text, :signature

      def initialize(text:, signature: nil)
        @text = text.to_s
        @signature = signature
      end

      def type
        :text
      end

      def to_h
        h = { type: :text, text: @text }
        h[:signature] = @signature if @signature
        h
      end

      def ==(other)
        other.is_a?(Text) && other.text == @text && other.signature == @signature
      end
      alias eql? ==

      def hash
        [self.class, @text, @signature].hash
      end
    end

    # A model's reasoning block. `signature` holds the opaque payload a provider
    # needs to replay the block on a later turn. `redacted` is true when a safety
    # filter hid the reasoning and only the signature remains.
    class Thinking
      attr_reader :thinking, :signature

      def initialize(thinking:, signature: nil, redacted: false)
        @thinking = thinking.to_s
        @signature = signature
        @redacted = redacted
      end

      def type
        :thinking
      end

      def redacted?
        @redacted
      end

      def to_h
        h = { type: :thinking, thinking: @thinking }
        h[:signature] = @signature if @signature
        h[:redacted] = true if @redacted
        h
      end

      def ==(other)
        other.is_a?(Thinking) && other.thinking == @thinking &&
          other.signature == @signature && other.redacted? == @redacted
      end
      alias eql? ==

      def hash
        [self.class, @thinking, @signature, @redacted].hash
      end
    end

    # A base64-encoded image with its MIME type, on a user or tool-result turn.
    class Image
      attr_reader :data, :mime_type

      def initialize(data:, mime_type:)
        @data = data
        @mime_type = mime_type
      end

      def type
        :image
      end

      def to_h
        { type: :image, data: @data, mime_type: @mime_type }
      end

      def ==(other)
        other.is_a?(Image) && other.data == @data && other.mime_type == @mime_type
      end
      alias eql? ==

      def hash
        [self.class, @data, @mime_type].hash
      end
    end
  end
end
