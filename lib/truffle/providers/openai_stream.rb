# frozen_string_literal: true

require "json"

module Truffle
  module Providers
    # Turns a sequence of OpenAI Chat Completions streaming chunks into the
    # ordered StreamEvent protocol and a final Response. A port of the chunk
    # handling in pi's packages/ai/src/api/openai-completions.ts `stream`
    # function: it opens one text block and one thinking block per turn, tracks
    # tool-call blocks by their stream index and id, and emits start/delta/end
    # events as content arrives, then a terminal done or error.
    #
    # The HTTP and SSE transport lives in Providers::OpenAI#chat_stream; this
    # class is fed already-parsed chunk hashes so its logic can be tested with no
    # network. Drive it by calling #feed for each chunk and #finish once the
    # stream closes (or #fail with the exception on a transport error), each with
    # a block that receives StreamEvents. #response holds the final Response.
    class OpenAIStream
      # The reasoning fields different OpenAI-compatible endpoints use, in priority
      # order. pi reads the first non-empty one to avoid double-counting providers
      # that echo the same text under two keys.
      REASONING_FIELDS = %w[reasoning_content reasoning reasoning_text].freeze

      attr_reader :response

      # pricing_model is the model id the caller requested, used to price the
      # final usage when the chunks do not carry a model of their own.
      def initialize(pricing_model: nil)
        @pricing_model = pricing_model
        @blocks = []
        @text_block = nil
        @thinking_block = nil
        @tool_by_index = {}
        @tool_by_id = {}
        @pending = []
        @started = false
        @has_finish_reason = false
        @stop_reason = StopReason::STOP
        @error_message = nil
        @raw_finish_reason = nil
        @usage = {}
        @model = nil
        @message = nil
        @response = nil
      end

      # Process one streaming chunk, yielding any events it produces.
      def feed(chunk)
        ensure_started
        process(chunk) if chunk.is_a?(Hash)
        drain { |event| yield event if block_given? }
      end

      # Close the stream: emit the *_end events for every open block, then the
      # terminal done or error. After this, #response is set.
      def finish
        ensure_started
        finalize
        drain { |event| yield event if block_given? }
      end

      # Abort the stream with a transport or parse failure: emit an error event
      # carrying the message decoded so far. Mirrors pi's catch path.
      def fail(error)
        ensure_started
        @stop_reason = StopReason::ERROR
        @error_message = error.is_a?(Exception) ? error.message : error.to_s
        @message = snapshot(final: true)
        @response = build_response
        push(StreamEvent.new(type: :error, reason: @stop_reason,
                             message: @message, error_message: @error_message))
        drain { |event| yield event if block_given? }
      end

      # Cancel the stream cooperatively: close out any open blocks and emit a
      # clean terminal carrying the partial message, with StopReason::ABORTED.
      # An abort is not a failure, so this is a :done event (no error_message),
      # unlike #fail. The missing finish_reason is expected here and is not
      # treated as the "stream ended without finish_reason" error.
      def abort
        ensure_started
        emit_block_ends
        @stop_reason = StopReason::ABORTED
        @error_message = nil
        @message = snapshot(final: true)
        @response = build_response
        push(StreamEvent.new(type: :done, reason: @stop_reason, message: @message))
        drain { |event| yield event if block_given? }
      end

      private

      def ensure_started
        return if @started

        @started = true
        push(event(:start))
      end

      def process(chunk)
        @model ||= chunk["model"] if chunk["model"].is_a?(String) && !chunk["model"].empty?
        @usage = chunk["usage"] if chunk["usage"]

        choice = Array(chunk["choices"]).first
        return unless choice

        # Some compatible endpoints report usage on the choice instead of the chunk.
        @usage = choice["usage"] if !chunk["usage"] && choice["usage"]

        if (reason = choice["finish_reason"])
          @raw_finish_reason = reason
          @stop_reason, error_message = OpenAI.map_stop_reason(reason)
          @error_message = error_message if error_message
          @has_finish_reason = true
        end

        delta = choice["delta"]
        return unless delta

        emit_text(delta)
        emit_thinking(delta)
        emit_tool_calls(delta)
      end

      def emit_text(delta)
        text = delta["content"]
        return unless text.is_a?(String) && !text.empty?

        block = ensure_text_block
        block.text << text
        push(event(:text_delta, content_index: index_of(block), delta: text))
      end

      def emit_thinking(delta)
        field = REASONING_FIELDS.find { |f| delta[f].is_a?(String) && !delta[f].empty? }
        return unless field

        value = delta[field]
        block = ensure_thinking_block(field)
        block.thinking << value
        push(event(:thinking_delta, content_index: index_of(block), delta: value))
      end

      def emit_tool_calls(delta)
        Array(delta["tool_calls"]).each do |raw|
          block = ensure_tool_call_block(raw)
          register_tool_call_ids(block, raw)
          function = raw["function"] || {}
          chunk_args = function["arguments"]
          piece = ""
          if chunk_args.is_a?(String) && !chunk_args.empty?
            piece = chunk_args
            block.partial_args << chunk_args
          end
          push(event(:toolcall_delta, content_index: index_of(block), delta: piece))
        end
      end

      def register_tool_call_ids(block, raw)
        if (block.id.nil? || block.id.empty?) && raw["id"]
          block.id = raw["id"]
          @tool_by_id[raw["id"]] = block
        end
        function = raw["function"] || {}
        block.name = function["name"] if (block.name.nil? || block.name.empty?) && function["name"]
      end

      def ensure_text_block
        return @text_block if @text_block

        @text_block = Block.new(:text)
        @blocks << @text_block
        push(event(:text_start, content_index: index_of(@text_block)))
        @text_block
      end

      def ensure_thinking_block(signature)
        return @thinking_block if @thinking_block

        @thinking_block = Block.new(:thinking, signature: signature)
        @blocks << @thinking_block
        push(event(:thinking_start, content_index: index_of(@thinking_block)))
        @thinking_block
      end

      def ensure_tool_call_block(raw)
        index = raw["index"]
        block = index.nil? ? nil : @tool_by_index[index]
        block ||= @tool_by_id[raw["id"]] if raw["id"]
        return block if block

        function = raw["function"] || {}
        block = Block.new(:toolcall, id: raw["id"].to_s, name: function["name"].to_s)
        @tool_by_index[index] = block unless index.nil?
        @tool_by_id[raw["id"]] = block if raw["id"]
        @blocks << block
        push(event(:toolcall_start, content_index: index_of(block)))
        block
      end

      def finalize
        emit_block_ends

        unless @has_finish_reason
          @stop_reason = StopReason::ERROR
          @error_message = "Stream ended without finish_reason"
        end

        @message = snapshot(final: true)
        @response = build_response

        if @stop_reason == StopReason::ERROR
          push(StreamEvent.new(type: :error, reason: @stop_reason,
                               message: @message, error_message: @error_message))
        else
          push(StreamEvent.new(type: :done, reason: @stop_reason, message: @message))
        end
      end

      # Close every open block with its *_end event. Shared by the normal finish
      # and by #abort, which both need the partial blocks sealed before the
      # terminal.
      def emit_block_ends
        @blocks.each do |block|
          index = index_of(block)
          case block.kind
          when :text
            push(event(:text_end, content_index: index, content: block.text.dup))
          when :thinking
            push(event(:thinking_end, content_index: index, content: block.thinking.dup))
          when :toolcall
            tool_call = ToolCall.new(id: block.id, name: block.name,
                                     arguments: parse_arguments(block.partial_args))
            push(event(:toolcall_end, content_index: index, tool_call: tool_call))
          end
        end
      end

      def build_response
        # Anchor pricing on the requested model, which the caller chose and
        # the catalog knows. The server-echoed @model can be a gateway-prefixed
        # id, a fine-tune, or a preview snapshot that is not in the catalog, so
        # pricing it would silently yield $0 despite real tokens. Fall back to
        # the echoed id only when the requested model is unpriceable.
        pricing = Pricing.cost_for(@pricing_model) || Pricing.cost_for(@model)
        Response.new(
          message: @message,
          usage: Usage.parse(@usage, pricing: pricing),
          model: @model,
          finish_reason: @raw_finish_reason,
          stop_reason: @stop_reason,
          error_message: @error_message
        )
      end

      # A streaming (non-terminal) event, carrying a snapshot of the message so
      # far so a consumer can render the whole turn without tracking deltas.
      def event(type, **fields)
        StreamEvent.new(type: type, partial: snapshot, **fields)
      end

      # Build an immutable assistant Message from the blocks accumulated so far.
      # Strings are duplicated so a snapshot taken now is not changed by later
      # deltas mutating the same block.
      def snapshot(final: false)
        content = @blocks.map { |block| materialize(block, final: final) }
        Message.assistant(content: content)
      end

      def materialize(block, final:)
        case block.kind
        when :text
          Content::Text.new(text: block.text.dup)
        when :thinking
          Content::Thinking.new(thinking: block.thinking.dup, signature: block.signature)
        when :toolcall
          arguments = if final
                        parse_arguments(block.partial_args)
                      else
                        parse_streaming_json(block.partial_args)
                      end
          ToolCall.new(id: block.id, name: block.name, arguments: arguments)
        end
      end

      def index_of(block)
        @blocks.index(block)
      end

      def push(event)
        @pending << event
      end

      def drain(&)
        @pending.each(&)
        @pending.clear
      end

      # Best-effort parse of an in-progress arguments buffer, for the live preview
      # on toolcall_delta/partial. Ports pi's parseStreamingJson path through the
      # zero-dep PartialJson parser.
      def parse_streaming_json(raw)
        PartialJson.parse_streaming(raw)
      end

      # Parse a completed arguments buffer. A model very occasionally emits
      # malformed JSON; repair string literals first, then surface unrepaired
      # input under a sentinel key, matching the non-streaming provider path.
      def parse_arguments(raw)
        Providers.parse_tool_arguments(raw)
      end

      # A mutable scratch block accumulated during a stream. Finalized into a
      # Content::Text, Content::Thinking, or ToolCall at the end.
      class Block
        attr_accessor :kind, :text, :thinking, :signature, :id, :name, :partial_args

        def initialize(kind, signature: nil, id: nil, name: nil)
          @kind = kind
          @text = +""
          @thinking = +""
          @signature = signature
          @id = id
          @name = name
          @partial_args = +""
        end
      end
    end
  end
end
