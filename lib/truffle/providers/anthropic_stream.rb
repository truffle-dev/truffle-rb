# frozen_string_literal: true

require "json"

module Truffle
  module Providers
    # Turns a sequence of Anthropic Messages streaming events into the ordered
    # StreamEvent protocol and a final Response. A port of the stream half of
    # pi's packages/ai/src/api/anthropic-messages.ts: message_start seeds the
    # response id and usage, each content_block_start/delta/stop drives one block
    # (text, thinking, redacted_thinking, or tool_use) keyed by its wire index,
    # and message_delta carries the stop reason and the final usage.
    #
    # The HTTP and SSE transport lives in Providers::Anthropic#chat_stream; this
    # class is fed already-parsed event hashes so its logic runs with no network.
    # Drive it by calling #feed for each event and #finish once the stream closes
    # (or #fail with the exception on a transport error), each with a block that
    # receives StreamEvents. #response holds the final Response. The public shape
    # matches OpenAIStream so the provider seam drives both the same way.
    class AnthropicStream
      attr_reader :response

      # pricing_model is the model id the caller requested, used to price the
      # final usage when message_start does not carry a model of its own.
      def initialize(pricing_model: nil)
        @pricing_model = pricing_model
        @blocks = []
        @by_index = {}
        @pending = []
        @usage = {}
        @model = nil
        @response_id = nil
        @started = false
        @saw_stop_reason = false
        @stop_reason = StopReason::STOP
        @raw_stop_reason = nil
        @error_message = nil
        @message = nil
        @response = nil
      end

      # Process one streaming event, yielding any StreamEvents it produces.
      def feed(frame)
        ensure_started
        process(frame) if frame.is_a?(Hash)
        drain { |event| yield event if block_given? }
      end

      # Close the stream: seal any block that did not get its content_block_stop,
      # then emit the terminal done or error. After this, #response is set.
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
      # An abort is not a failure, so this is a :done event (no error_message).
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

      def process(frame)
        case frame["type"]
        when "message_start" then on_message_start(frame)
        when "content_block_start" then on_block_start(frame)
        when "content_block_delta" then on_block_delta(frame)
        when "content_block_stop" then on_block_stop(frame)
        when "message_delta" then on_message_delta(frame)
        when "error" then on_error_event(frame)
        end
      end

      def on_message_start(frame)
        message = frame["message"] || {}
        @response_id = message["id"]
        @model ||= message["model"] if message["model"].is_a?(String) && !message["model"].empty?
        merge_usage(message["usage"])
      end

      def on_block_start(frame)
        index = frame["index"]
        cb = frame["content_block"] || {}
        case cb["type"]
        when "text"
          start_block(index, :text, :text_start)
        when "thinking"
          start_block(index, :thinking, :thinking_start)
        when "redacted_thinking"
          start_block(index, :thinking, :thinking_start,
                      thinking: "[Reasoning redacted]", signature: cb["data"], redacted: true)
        when "tool_use"
          start_block(index, :toolcall, :toolcall_start, id: cb["id"].to_s, name: cb["name"].to_s)
        end
      end

      def start_block(index, kind, start_type, **attrs)
        block = Block.new(kind, **attrs)
        @by_index[index] = block
        @blocks << block
        push(event(start_type, content_index: index_of(block)))
      end

      def on_block_delta(frame)
        block = @by_index[frame["index"]]
        return unless block

        delta = frame["delta"] || {}
        case delta["type"]
        when "text_delta" then append_text(block, delta["text"].to_s)
        when "thinking_delta" then append_thinking(block, delta["thinking"].to_s)
        when "input_json_delta" then append_tool_args(block, delta["partial_json"].to_s)
        when "signature_delta" then block.signature = "#{block.signature}#{delta["signature"]}"
        end
      end

      def append_text(block, text)
        block.text << text
        push(event(:text_delta, content_index: index_of(block), delta: text))
      end

      def append_thinking(block, text)
        block.thinking << text
        push(event(:thinking_delta, content_index: index_of(block), delta: text))
      end

      def append_tool_args(block, piece)
        block.partial_args << piece
        push(event(:toolcall_delta, content_index: index_of(block), delta: piece))
      end

      def on_block_stop(frame)
        block = @by_index[frame["index"]]
        emit_block_end(block) if block
      end

      def on_message_delta(frame)
        delta = frame["delta"] || {}
        if (raw = delta["stop_reason"])
          @raw_stop_reason = raw
          @stop_reason, message = Anthropic.map_stop_reason(raw, delta["stop_details"])
          @error_message = message if message
          @saw_stop_reason = true
        end
        merge_usage(frame["usage"])
      end

      # An Anthropic mid-stream error event (overloaded_error, api_error). Fold it
      # into the terminal the way pi's thrown error does, without crashing.
      def on_error_event(frame)
        error = frame["error"] || {}
        @stop_reason = StopReason::ERROR
        @error_message = error["message"] || "Anthropic stream error"
        @saw_stop_reason = true
      end

      # Accumulate the usage fields Anthropic spreads across message_start and
      # message_delta. Only non-nil fields overwrite, so input_tokens captured at
      # message_start survives a message_delta that omits it (pi does the same).
      def merge_usage(raw)
        return unless raw.is_a?(Hash)

        %w[input_tokens output_tokens cache_read_input_tokens
           cache_creation_input_tokens].each do |key|
          @usage[key] = raw[key] unless raw[key].nil?
        end
        @usage["cache_creation"] = raw["cache_creation"] if raw["cache_creation"]
        return unless raw["output_tokens_details"]

        @usage["output_tokens_details"] = raw["output_tokens_details"]
      end

      def finalize
        emit_block_ends

        unless @saw_stop_reason
          @stop_reason = StopReason::ERROR
          @error_message = "Stream ended before message_stop"
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

      # Close every block that has not already had its content_block_stop. Normal
      # streams close each block as it stops, so this is a no-op at finish; on an
      # abort mid-block it seals whatever is still open.
      def emit_block_ends
        @blocks.each { |block| emit_block_end(block) }
      end

      def emit_block_end(block)
        return if block.closed

        block.closed = true
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

      def build_response
        # Anchor pricing on the requested model, which the caller chose and
        # the catalog knows. The server-echoed @model can be a gateway-prefixed
        # id, a fine-tune, or a preview snapshot that is not in the catalog, so
        # pricing it would silently yield $0 despite real tokens. Fall back to
        # the echoed id only when the requested model is unpriceable.
        pricing = Pricing.cost_for(@pricing_model) || Pricing.cost_for(@model)
        Response.new(
          message: @message,
          usage: Usage.from_anthropic(@usage, pricing: pricing),
          model: @model,
          finish_reason: @raw_stop_reason,
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
      # Strings are duplicated so a snapshot taken now is not mutated by later
      # deltas appending to the same block.
      def snapshot(final: false)
        content = @blocks.map { |block| materialize(block, final: final) }
        Message.assistant(content: content)
      end

      def materialize(block, final:)
        case block.kind
        when :text
          Content::Text.new(text: block.text.dup)
        when :thinking
          Content::Thinking.new(thinking: block.thinking.dup, signature: block.signature,
                                redacted: block.redacted)
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

      # A mutable scratch block accumulated during a stream, finalized into a
      # Content::Text, Content::Thinking, or ToolCall once its block stops.
      class Block
        attr_accessor :kind, :text, :thinking, :signature, :id, :name,
                      :partial_args, :redacted, :closed

        def initialize(kind, signature: nil, id: nil, name: nil, thinking: nil, redacted: false)
          @kind = kind
          @text = +""
          @thinking = +(thinking || "")
          @signature = signature
          @id = id
          @name = name
          @partial_args = +""
          @redacted = redacted
          @closed = false
        end
      end
    end
  end
end
