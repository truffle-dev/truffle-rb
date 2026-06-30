# frozen_string_literal: true

require "json"

module Truffle
  module Providers
    # Turns a sequence of Gemini streamGenerateContent chunks into the ordered
    # StreamEvent protocol and a final Response. A port of the stream half of pi's
    # packages/ai/src/api/google-generative-ai.ts.
    #
    # Gemini does not stream indexed block events the way Anthropic does; each SSE
    # chunk is a whole GenerateContentResponse whose candidate carries the parts
    # produced since the last chunk. So this accumulator keeps a single open
    # text-or-thinking block and appends each chunk's text to it, closing it and
    # opening a fresh one when the part kind flips (text to thought or back) or a
    # functionCall arrives. A functionCall is emitted as a complete start/delta/end
    # trio in one go, since Gemini sends the whole call in a single part. The
    # finishReason rides on the candidate and is overridden to tool_use when the
    # turn produced a call, the way the non-streaming path does; usageMetadata is
    # cumulative, so the last chunk that carries it wins.
    #
    # The HTTP and SSE transport lives in Providers::Google#chat_stream (over the
    # shared Providers::SSE mixin); this class is fed already-parsed chunk hashes
    # so its logic runs with no network. Drive it by calling #feed for each chunk
    # and #finish once the stream closes (or #fail with the exception on a
    # transport error, #abort on a cancel), each with a block that receives
    # StreamEvents. #response holds the final Response. The public shape matches
    # AnthropicStream and OpenAIStream so the provider seam drives all three the
    # same way.
    class GoogleStream
      attr_reader :response

      # pricing_model is the model id the caller requested, used to price the
      # final usage and label the response when chunks omit a modelVersion.
      def initialize(pricing_model: nil)
        @pricing_model = pricing_model
        @blocks = []
        @current = nil
        @used_ids = {}
        @tool_counter = 0
        @pending = []
        @usage = {}
        @model = nil
        @response_id = nil
        @started = false
        @stop_reason = StopReason::STOP
        @raw_stop_reason = nil
        @error_message = nil
        @message = nil
        @response = nil
      end

      # Process one streaming chunk, yielding any StreamEvents it produces.
      def feed(frame)
        ensure_started
        process(frame) if frame.is_a?(Hash)
        drain { |event| yield event if block_given? }
      end

      # Close the stream: seal the open block, then emit the terminal done or
      # error. After this, #response is set. A clean Gemini stream needs no
      # explicit stop event, so reaching the end is a normal :done unless a
      # finishReason mapped to an error along the way.
      def finish
        ensure_started
        finalize
        drain { |event| yield event if block_given? }
      end

      # Abort the stream with a transport or parse failure: emit an error event
      # carrying the message decoded so far. Mirrors pi's catch path.
      def fail(error)
        ensure_started
        close_current
        @stop_reason = StopReason::ERROR
        @error_message = error.is_a?(Exception) ? error.message : error.to_s
        @message = snapshot(final: true)
        @response = build_response
        push(StreamEvent.new(type: :error, reason: @stop_reason,
                             message: @message, error_message: @error_message))
        drain { |event| yield event if block_given? }
      end

      # Cancel the stream cooperatively: close the open block and emit a clean
      # terminal carrying the partial message, with StopReason::ABORTED. An abort
      # is not a failure, so this is a :done event (no error_message).
      def abort
        ensure_started
        close_current
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
        @response_id ||= frame["responseId"]
        version = frame["modelVersion"]
        @model ||= version if version.is_a?(String) && !version.empty?

        candidate = Array(frame["candidates"]).first
        if candidate
          process_parts(candidate)
          apply_finish(candidate["finishReason"]) if candidate["finishReason"]
        end
        merge_usage(frame["usageMetadata"])
      end

      def process_parts(candidate)
        content = candidate["content"] || {}
        Array(content["parts"]).each do |part|
          if part.key?("text")
            handle_text(part)
          elsif part.key?("functionCall")
            handle_function_call(part)
          end
        end
      end

      # Append a text or thought part to the open block, opening a fresh block
      # (and closing the previous one) when the part's kind differs from the block
      # currently open. A thought part carries thought: true.
      def handle_text(part)
        thinking = part["thought"] == true
        if @current.nil? || @current.kind != (thinking ? :thinking : :text)
          open_text_block(thinking)
        end

        text = part["text"].to_s
        @current.signature = retain_signature(@current.signature, part["thoughtSignature"])
        index = index_of(@current)
        if thinking
          @current.thinking << text
          push(event(:thinking_delta, content_index: index, delta: text))
        else
          @current.text << text
          push(event(:text_delta, content_index: index, delta: text))
        end
      end

      def open_text_block(thinking)
        close_current
        @current = Block.new(thinking ? :thinking : :text)
        @blocks << @current
        start_type = thinking ? :thinking_start : :text_start
        push(event(start_type, content_index: index_of(@current)))
      end

      # A functionCall part: close any open text/thinking block, then emit the
      # whole call as a start/delta/end trio. Gemini rarely returns a call id over
      # the wire and can repeat one, so a missing or duplicate id is replaced with
      # a deterministic name-and-counter id, enough to link the result back.
      def handle_function_call(part)
        close_current
        call = part["functionCall"] || {}
        block = Block.new(:toolcall, id: tool_call_id(call), name: call["name"].to_s,
                                     arguments: call["args"] || {})
        @blocks << block
        index = index_of(block)
        tool_call = ToolCall.new(id: block.id, name: block.name, arguments: block.arguments)
        push(event(:toolcall_start, content_index: index))
        push(event(:toolcall_delta, content_index: index, delta: JSON.generate(block.arguments)))
        push(event(:toolcall_end, content_index: index, tool_call: tool_call))
      end

      def tool_call_id(call)
        provided = call["id"]
        if provided.nil? || provided.to_s.empty? || @used_ids.key?(provided)
          id = "#{call["name"]}-#{@tool_counter}"
          @tool_counter += 1
        else
          id = provided
        end
        @used_ids[id] = true
        id
      end

      # Map the candidate's finishReason onto a stop reason, then override to
      # tool_use when the turn produced a call (Gemini reports a plain STOP even
      # then), the way the non-streaming Google path does.
      def apply_finish(raw)
        @raw_stop_reason = raw
        @stop_reason, @error_message = Google.map_stop_reason(raw)
        return unless @blocks.any? { |block| block.kind == :toolcall }

        @stop_reason = StopReason::TOOL_USE
        @error_message = nil
      end

      # Gemini reports cumulative usage, so the latest usageMetadata is the whole
      # turn's count; keep the most recent one for the final Usage.from_google.
      def merge_usage(raw)
        @usage = raw if raw.is_a?(Hash)
      end

      def finalize
        close_current
        @message = snapshot(final: true)
        @response = build_response
        if @stop_reason == StopReason::ERROR
          push(StreamEvent.new(type: :error, reason: @stop_reason,
                               message: @message, error_message: @error_message))
        else
          push(StreamEvent.new(type: :done, reason: @stop_reason, message: @message))
        end
      end

      def close_current
        block = @current
        return unless block

        @current = nil
        index = index_of(block)
        if block.kind == :text
          push(event(:text_end, content_index: index, content: block.text.dup))
        else
          push(event(:thinking_end, content_index: index, content: block.thinking.dup))
        end
      end

      def build_response
        model = @model || @pricing_model
        # Anchor pricing on the requested model, which the caller chose and the
        # catalog knows. The server-echoed @model can be a gateway-prefixed id,
        # a fine-tune, or a preview snapshot that is not in the catalog, so
        # pricing it would silently yield $0 despite real tokens. Fall back to
        # the echoed id only when the requested model is unpriceable. The
        # reported model stays the echoed id.
        pricing = Pricing.cost_for(@pricing_model) || Pricing.cost_for(@model)
        Response.new(
          message: @message,
          usage: Usage.from_google(@usage, pricing: pricing),
          model: model,
          finish_reason: @raw_stop_reason,
          stop_reason: @stop_reason,
          error_message: @error_message
        )
      end

      # A streaming (non-terminal) event carrying a snapshot of the message so
      # far, so a consumer can render the whole turn without tracking deltas.
      def event(type, **fields)
        StreamEvent.new(type: type, partial: snapshot, **fields)
      end

      # Build an immutable assistant Message from the blocks accumulated so far.
      # Tool calls live inline in the content list (Message.assistant appends
      # them), so a block's wire index lines up with its content_index. Strings
      # are duplicated so a snapshot taken now is not mutated by a later delta.
      def snapshot(final: false)
        _ = final
        content = @blocks.map { |block| materialize(block) }
        Message.assistant(content: content)
      end

      def materialize(block)
        case block.kind
        when :text
          Content::Text.new(text: block.text.dup, signature: block.signature)
        when :thinking
          Content::Thinking.new(thinking: block.thinking.dup, signature: block.signature)
        when :toolcall
          ToolCall.new(id: block.id, name: block.name, arguments: block.arguments)
        end
      end

      # Keep the latest non-empty thought signature, the way pi's
      # retainThoughtSignature does: a later chunk's signature wins, but an empty
      # one never clobbers a signature already seen.
      def retain_signature(current, incoming)
        return current if incoming.nil? || incoming.empty?

        incoming
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

      # A mutable scratch block accumulated during a stream, finalized into a
      # Content::Text, Content::Thinking, or ToolCall once the turn closes.
      class Block
        attr_accessor :kind, :text, :thinking, :signature, :id, :name, :arguments

        def initialize(kind, id: nil, name: nil, arguments: nil)
          @kind = kind
          @text = +""
          @thinking = +""
          @signature = nil
          @id = id
          @name = name
          @arguments = arguments
        end
      end
    end
  end
end
