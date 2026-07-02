# frozen_string_literal: true

require "json"

module Truffle
  module Providers
    # The OpenAI Responses API item vocabulary, shared by the OpenAIResponses
    # provider and its stream accumulator the way pi splits the same code into
    # packages/ai/src/api/openai-responses-shared.ts. Both halves speak in
    # typed items - reasoning, message, function_call, function_call_output -
    # so the conversions between those items and Truffle's content blocks live
    # here once: building the input array for a request, rebuilding an
    # assistant Message from an output array, the signature round-trips that
    # keep reasoning and message metadata across stateless turns, and the
    # status-to-StopReason mapping.
    #
    # Two signatures carry the round-trip state. A reasoning output item
    # persists whole (id, summary, and encrypted_content included) as the JSON
    # signature of its Content::Thinking block, so the next request can replay
    # the item verbatim. A message item's id and phase fold into the Text block
    # signature as pi's TextSignatureV1 ({"v":1,"id":...,"phase":...}).
    module OpenAIResponsesShared
      # The assistant-item phases the API defines; anything else on a replayed
      # signature is dropped rather than echoed back.
      PHASES = %w[commentary final_answer].freeze

      module_function

      # Convert Truffle messages into Responses input items. System messages
      # stay in the input list as system-role messages; a user turn is a string
      # or an input_text/input_image part array; an assistant turn expands into
      # its typed items (reasoning, message, function_call) in content order so
      # a reasoning item still precedes the tool call it produced; a tool result
      # is a function_call_output linked back by call_id.
      def convert_messages(messages)
        items = []
        messages.each_with_index do |message, index|
          case message.role
          when :system
            items << { role: "system", content: Providers.sanitize_text(message.text.to_s) }
          when :user
            content = user_content(message)
            items << { role: "user", content: content } unless empty_content?(content)
          when :assistant
            items.concat(assistant_items(message, index))
          when :tool
            items << {
              type: "function_call_output",
              call_id: message.tool_call_id,
              output: tool_output(message)
            }
          end
        end
        items
      end

      # Render user content the way the chat provider does: a plain string when
      # there is no image, otherwise a part array of input_text and base64
      # data-URL input_image blocks.
      def user_content(message)
        unless message.content.any?(Content::Image)
          return Providers.sanitize_text(message.text.to_s)
        end

        message.content.filter_map do |block|
          case block
          when Content::Text
            text = Providers.sanitize_text(block.text)
            next if text.empty?

            { type: "input_text", text: text }
          when Content::Image
            image_part(block)
          end
        end
      end

      # The assistant turn's content blocks as Responses input items, in order.
      # A thinking block replays as its stored reasoning item (the signature is
      # the item itself as JSON); one without a replayable signature - unsigned,
      # or signed by another provider - is skipped, since the API rejects
      # reasoning it did not produce and echoing it as visible text would
      # double-render the turn. A text block becomes a message item carrying its
      # original id and phase when the signature has them (a fresh id
      # otherwise), and a tool call becomes a function_call item. The
      # function_call carries no item id: OpenAI validates that a returned
      # fc_... id still pairs with its rs_... reasoning item, and omitting the
      # id sidesteps that check the way pi's cross-model path does.
      def assistant_items(message, index)
        items = []
        text_index = 0
        message.content.each do |block|
          case block.type
          when :thinking
            item = reasoning_item(block)
            items << item if item
          when :text
            items << message_item(block, index, text_index)
            text_index += 1
          when :tool_call
            items << {
              type: "function_call",
              call_id: block.id,
              name: block.name,
              arguments: JSON.generate(block.arguments || {})
            }
          end
        end
        items
      end

      # Rebuild the reasoning item a thinking block's signature stores. Returns
      # nil when the signature is absent or is not a reasoning item (an
      # Anthropic signature, say), which drops the block from the replay.
      def reasoning_item(block)
        return nil if block.signature.nil? || block.signature.empty?

        item = JSON.parse(block.signature)
        item.is_a?(Hash) && item["type"] == "reasoning" ? item : nil
      rescue JSON::ParserError
        nil
      end

      def message_item(block, message_index, text_index)
        parsed = parse_text_signature(block.signature)
        item = {
          type: "message",
          role: "assistant",
          content: [{ type: "output_text",
                      text: Providers.sanitize_text(block.text), annotations: [] }],
          status: "completed",
          id: message_id(parsed, message_index, text_index)
        }
        item[:phase] = parsed[:phase] if parsed && parsed[:phase]
        item
      end

      # The message item id to replay: the original one when the signature kept
      # it (folded through ShortHash when it exceeds the API's 64-character
      # cap), or a deterministic fresh id for text that never came from this
      # API.
      def message_id(parsed, message_index, text_index)
        id = parsed && parsed[:id]
        if id.nil? || id.empty?
          suffix = text_index.zero? ? "" : "_#{text_index}"
          "msg_truffle_#{message_index}#{suffix}"
        elsif id.length > 64
          "msg_#{ShortHash.of(id)}"
        else
          id
        end
      end

      # Encode a message item's id and phase into a Text block signature, pi's
      # TextSignatureV1 shape: {"v":1,"id":"msg_...","phase":"commentary"}.
      def encode_text_signature(id, phase = nil)
        payload = { v: 1, id: id }
        payload[:phase] = phase if PHASES.include?(phase)
        JSON.generate(payload)
      end

      # Decode a Text block signature back to its id and phase. A signature
      # that is not a V1 payload is treated as a bare id (the legacy plain
      # string form). Returns nil when there is no signature at all.
      def parse_text_signature(signature)
        return nil if signature.nil? || signature.empty?

        if signature.start_with?("{")
          begin
            parsed = JSON.parse(signature)
            if parsed["v"] == 1 && parsed["id"].is_a?(String)
              phase = parsed["phase"]
              return { id: parsed["id"], phase: PHASES.include?(phase) ? phase : nil }
            end
          rescue JSON::ParserError
            # Fall through to the legacy plain-string handling.
          end
        end
        { id: signature, phase: nil }
      end

      # One function_call_output for a :tool message. A text-only result is a
      # plain string; a result carrying images becomes an input_text/input_image
      # part list, so a tool can hand the model a screenshot directly.
      def tool_output(message)
        images = message.content.grep(Content::Image)
        text = Providers.sanitize_text(message.text.to_s)
        return text if images.empty?

        parts = []
        parts << { type: "input_text", text: text } unless text.empty?
        images.each { |image| parts << image_part(image) }
        parts
      end

      def image_part(image)
        { type: "input_image", detail: "auto",
          image_url: "data:#{image.mime_type};base64,#{image.data}" }
      end

      def empty_content?(content)
        content.is_a?(String) ? content.strip.empty? : content.empty?
      end

      # Convert provider-neutral tool schemas (Toolbox#to_schema) into Responses
      # function tools: name, description, and parameters sit at the top level
      # of the tool object rather than under a "function" wrapper. strict
      # defaults on server-side, so it is pinned false to keep the neutral
      # schemas valid as-is.
      def convert_tools(tools)
        tools.map do |tool|
          {
            type: "function",
            name: tool[:name],
            description: tool[:description],
            parameters: tool[:parameters] || {},
            strict: false
          }
        end
      end

      # Rebuild a Truffle assistant Message from a Responses output array. Items
      # stay in wire order inside the content list - a reasoning item before a
      # function_call must replay in that order - so tool calls ride in content
      # rather than through the tool_calls side channel. A reasoning item's
      # visible text is its summary parts (or raw reasoning text when the model
      # exposes it) and the whole item persists as the signature; a message item
      # keeps its id and phase on the Text signature; refusal parts read as
      # text, the way pi folds them.
      def deserialize_message(output)
        blocks = Array(output).filter_map do |item|
          case item["type"]
          when "reasoning"
            Content::Thinking.new(thinking: reasoning_text(item),
                                  signature: JSON.generate(item))
          when "message"
            Content::Text.new(text: message_text(item),
                              signature: encode_text_signature(item["id"], item["phase"]))
          when "function_call"
            ToolCall.new(id: item["call_id"], name: item["name"],
                         arguments: Providers.parse_tool_arguments(item["arguments"]))
          end
        end
        Message.assistant(content: blocks)
      end

      def reasoning_text(item)
        summary = Array(item["summary"]).map { |part| part["text"].to_s }.join("\n\n")
        return summary unless summary.empty?

        Array(item["content"]).map { |part| part["text"].to_s }.join("\n\n")
      end

      def message_text(item)
        Array(item["content"]).map do |part|
          part["type"] == "refusal" ? part["refusal"].to_s : part["text"].to_s
        end.join
      end

      # Map a Responses status onto a Truffle::StopReason plus an error message
      # when it signals a failure. A port of pi's mapStopReason for this API:
      # completed is a clean stop (the caller upgrades it to :tool_use when the
      # turn carries tool calls, since this API has no tool_calls status),
      # incomplete is a length cutoff unless incomplete_details says the content
      # filter cut it, failed and cancelled carry the response error, and
      # in_progress/queued fold to a clean stop the way pi shrugs at them.
      def map_stop_reason(status, incomplete_reason: nil, error: nil)
        case status
        when "completed", "in_progress", "queued", nil then [StopReason::STOP, nil]
        when "incomplete"
          if incomplete_reason == "content_filter"
            [StopReason::ERROR, "Response incomplete: content_filter"]
          else
            [StopReason::LENGTH, nil]
          end
        when "failed", "cancelled"
          [StopReason::ERROR, error_text(error) || "Provider status: #{status}"]
        else [StopReason::ERROR, "Provider status: #{status}"]
        end
      end

      def error_text(error)
        return nil unless error.is_a?(Hash)

        code = error["code"]
        message = error["message"]
        return nil if code.nil? && message.nil?

        [code, message].compact.join(": ")
      end
    end
  end
end
