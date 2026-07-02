# frozen_string_literal: true

require "json"

module Truffle
  module Providers
    # Turns a sequence of OpenAI Responses streaming events into the ordered
    # StreamEvent protocol and a final Response. A port of pi's
    # processResponsesStream (packages/ai/src/api/openai-responses-shared.ts):
    # response.output_item.added opens one block per output item (reasoning,
    # message, or function_call) keyed by its output_index, the typed delta
    # events drive it (reasoning summary and reasoning text as thinking, output
    # text and refusals as text, function-call arguments as tool-call JSON), and
    # response.output_item.done seals it with the item's authoritative content -
    # a reasoning item persisting whole (encrypted_content included) as the
    # thinking signature, a message item's id and phase folding into the text
    # signature. response.completed/incomplete/failed carry the final usage and
    # status. Each block accumulates exactly one kind of content, so a single
    # buffer per block backs text, thinking, and argument JSON alike.
    #
    # The HTTP and SSE transport lives in Providers::OpenAIResponses#chat_stream;
    # this class is fed already-parsed event hashes so its logic runs with no
    # network. Drive it by calling #feed for each event and #finish once the
    # stream closes (or #fail with the exception on a transport error), each
    # with a block that receives StreamEvents. #response holds the final
    # Response. The public shape matches the other stream accumulators so the
    # provider seam drives them all the same way.
    class OpenAIResponsesStream
      attr_reader :response

      # pricing_model is the model id the caller requested, used to price the
      # final usage when response.created does not carry a model of its own.
      def initialize(pricing_model: nil)
        @pricing_model = pricing_model
        @blocks = []
        @by_index = {}
        @pending = []
        @usage = nil
        @model = nil
        @response_id = nil
        @started = false
        @saw_terminal_event = false
        @stop_reason = StopReason::STOP
        @raw_status = nil
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

      # Close the stream: seal any block that did not get its output_item.done,
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
        seal_terminal(:error)
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
        seal_terminal(:done)
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
        when "response.created" then on_created(frame["response"] || {})
        when "response.output_item.added" then open_item(frame["output_index"], frame["item"])
        when "response.reasoning_summary_text.delta",
             "response.reasoning_text.delta" then on_delta(frame, :thinking, :thinking_delta)
        when "response.output_text.delta",
             "response.refusal.delta" then on_delta(frame, :text, :text_delta)
        when "response.function_call_arguments.delta"
          on_delta(frame, :toolcall, :toolcall_delta)
        when "response.function_call_arguments.done" then on_arguments_done(frame)
        when "response.reasoning_summary_part.done" then on_summary_part_done(frame)
        when "response.output_item.done" then on_item_done(frame)
        when "response.completed", "response.incomplete",
             "response.failed" then on_terminal(frame)
        when "error" then on_error_event(frame)
        end
      end

      def on_created(response)
        @response_id = response["id"]
        model = response["model"]
        @model ||= model if model.is_a?(String) && !model.empty?
      end

      # Open a block for a new output item. Item types this protocol does not
      # carry (web_search_call, code_interpreter_call, ...) get no block and
      # their deltas fall through silently.
      def open_item(index, item)
        item ||= {}
        case item["type"]
        when "reasoning"
          start_block(index, :thinking, :thinking_start)
        when "message"
          start_block(index, :text, :text_start)
        when "function_call"
          block = start_block(index, :toolcall, :toolcall_start,
                              id: item["call_id"].to_s, name: item["name"].to_s)
          args = item["arguments"]
          block.buffer << args if args.is_a?(String)
          block
        end
      end

      def start_block(index, kind, start_type, **attrs)
        block = Block.new(kind, **attrs)
        @by_index[index] = block
        @blocks << block
        push(event(start_type, content_index: index_of(block)))
        block
      end

      # Route one delta onto its block's buffer when the indexed block is of
      # the expected kind. Refusal deltas ride the text channel and raw
      # reasoning text rides the thinking channel, the way pi folds them.
      def on_delta(frame, kind, event_type)
        block = @by_index[frame["output_index"]]
        return unless block&.kind == kind

        delta = frame["delta"].to_s
        block.buffer << delta
        push(event(event_type, content_index: index_of(block), delta: delta))
      end

      # A summary is a list of parts; pi separates consecutive parts with a
      # blank line so the streamed thinking reads as paragraphs. The final text
      # is replaced wholesale at output_item.done, which never carries the
      # trailing separator.
      def on_summary_part_done(frame)
        block = @by_index[frame["output_index"]]
        return unless block&.kind == :thinking

        block.buffer << "\n\n"
        push(event(:thinking_delta, content_index: index_of(block), delta: "\n\n"))
      end

      # arguments.done carries the authoritative full buffer. When it extends
      # what the deltas built, the remainder is emitted as one more delta so a
      # consumer tracking deltas stays in sync; either way the buffer is
      # replaced, matching pi.
      def on_arguments_done(frame)
        block = @by_index[frame["output_index"]]
        return unless block&.kind == :toolcall

        final = frame["arguments"].to_s
        if final.start_with?(block.buffer) && final.length > block.buffer.length
          push(event(:toolcall_delta, content_index: index_of(block),
                                      delta: final[block.buffer.length..]))
        end
        block.buffer = +final
      end

      # Seal a block with its item's authoritative content. An item that never
      # got its output_item.added (a function_call that streamed no argument
      # deltas, say) is opened here first so it still emits a full
      # start/end pair.
      def on_item_done(frame)
        item = frame["item"] || {}
        block = @by_index[frame["output_index"]] || open_item(frame["output_index"], item)
        return unless block

        case block.kind
        when :thinking then finalize_thinking(block, item)
        when :text then finalize_text(block, item)
        when :toolcall then finalize_toolcall(block, item)
        end
      end

      def finalize_thinking(block, item)
        text = OpenAIResponsesShared.reasoning_text(item)
        block.buffer = +text unless text.empty?
        block.signature = JSON.generate(item)
        block.closed = true
        push(event(:thinking_end, content_index: index_of(block), content: block.buffer.dup))
      end

      def finalize_text(block, item)
        text = OpenAIResponsesShared.message_text(item)
        block.buffer = +text unless text.empty?
        block.signature = OpenAIResponsesShared.encode_text_signature(item["id"], item["phase"])
        block.closed = true
        push(event(:text_end, content_index: index_of(block), content: block.buffer.dup))
      end

      def finalize_toolcall(block, item)
        block.id = item["call_id"] if block.id.to_s.empty? && item["call_id"]
        block.name = item["name"] if block.name.to_s.empty? && item["name"]
        args = item["arguments"]
        block.buffer = +args if args.is_a?(String) && !args.empty?
        block.closed = true
        tool_call = ToolCall.new(id: block.id, name: block.name,
                                 arguments: Providers.parse_tool_arguments(block.buffer))
        push(event(:toolcall_end, content_index: index_of(block), tool_call: tool_call))
      end

      # response.completed, response.incomplete, or response.failed: the final
      # usage and status, mapped onto a stop reason (failed carries the
      # response error into the message).
      def on_terminal(frame)
        response = frame["response"] || {}
        @saw_terminal_event = true
        @response_id = response["id"] if response["id"]
        @usage = response["usage"] if response["usage"]
        @raw_status = response["status"]
        @stop_reason, message = OpenAIResponsesShared.map_stop_reason(
          @raw_status,
          incomplete_reason: response.dig("incomplete_details", "reason"),
          error: response["error"]
        )
        @error_message = message if message
      end

      # A mid-stream error event. Fold it into the terminal the way pi's thrown
      # error does, without crashing.
      def on_error_event(frame)
        @saw_terminal_event = true
        @stop_reason = StopReason::ERROR
        @error_message = [frame["code"], frame["message"]].compact.join(": ")
        @error_message = "OpenAI Responses stream error" if @error_message.empty?
      end

      def finalize
        emit_block_ends

        unless @saw_terminal_event
          @stop_reason = StopReason::ERROR
          @error_message = "Stream ended before response.completed"
        end

        # This API has no tool_calls status: a turn that requested tools still
        # completes as "completed", so the upgrade happens here, matching pi.
        if @stop_reason == StopReason::STOP && @blocks.any? { |b| b.kind == :toolcall }
          @stop_reason = StopReason::TOOL_USE
        end

        seal_terminal(@stop_reason == StopReason::ERROR ? :error : :done)
      end

      # Set the final message and response, then push the terminal event that
      # every closing path (finish, fail, abort) ends the stream with.
      def seal_terminal(type)
        @message = snapshot(final: true)
        @response = build_response
        push(StreamEvent.new(type: type, reason: @stop_reason, message: @message,
                             error_message: type == :error ? @error_message : nil))
      end

      # Close every block that has not already had its output_item.done. Normal
      # streams close each block as its item completes, so this is a no-op at
      # finish; on an abort mid-block it seals whatever is still open.
      def emit_block_ends
        @blocks.each { |block| emit_block_end(block) }
      end

      def emit_block_end(block)
        return if block.closed

        block.closed = true
        index = index_of(block)
        case block.kind
        when :text
          push(event(:text_end, content_index: index, content: block.buffer.dup))
        when :thinking
          push(event(:thinking_end, content_index: index, content: block.buffer.dup))
        when :toolcall
          tool_call = ToolCall.new(id: block.id, name: block.name,
                                   arguments: Providers.parse_tool_arguments(block.buffer))
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
          usage: Usage.from_openai_responses(@usage, pricing: pricing),
          model: @model,
          finish_reason: @raw_status,
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
      # deltas appending to the same block. A final snapshot parses tool
      # arguments through the repair path; a live one parses the partial JSON
      # best-effort, both matching the other accumulators.
      def snapshot(final: false)
        content = @blocks.map { |block| materialize(block, final: final) }
        Message.assistant(content: content)
      end

      def materialize(block, final:)
        case block.kind
        when :text
          Content::Text.new(text: block.buffer.dup, signature: block.signature)
        when :thinking
          Content::Thinking.new(thinking: block.buffer.dup, signature: block.signature)
        when :toolcall
          arguments = if final
                        Providers.parse_tool_arguments(block.buffer)
                      else
                        PartialJson.parse_streaming(block.buffer)
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

      # A mutable scratch block accumulated during a stream, finalized into a
      # Content::Text, Content::Thinking, or ToolCall once its item completes.
      # buffer holds the block's one accumulating string: visible text,
      # thinking text, or argument JSON, depending on kind.
      class Block
        attr_accessor :kind, :buffer, :signature, :id, :name, :closed

        def initialize(kind, id: nil, name: nil)
          @kind = kind
          @buffer = +""
          @signature = nil
          @id = id
          @name = name
          @closed = false
        end
      end
    end
  end
end
