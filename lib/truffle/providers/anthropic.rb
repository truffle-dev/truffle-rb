# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module Truffle
  module Providers
    # Anthropic Messages API provider with tool calling.
    #
    # Dependency-free like the OpenAI provider: it speaks the Messages API
    # directly with Net::HTTP and the stdlib JSON, no @anthropic-ai/sdk-style
    # client gem. A port of the wire shapes in pi's
    # packages/ai/src/api/anthropic-messages.ts, the parts that matter for a
    # single non-streaming turn: the system prompt is a top-level field rather
    # than a message, message content is block arrays, tool calls are tool_use
    # blocks, tool results come back as a user message of tool_result blocks
    # (consecutive results coalesced into one user message), and stop reasons
    # and usage map onto Truffle's normalized shapes.
    #
    # This is the non-streaming half of pi's Anthropic surface. pi only streams;
    # Truffle's agent loop drives #chat, so a single buffered request is the
    # focused first slice. A streaming #chat_stream over the same wire transforms
    # (an AnthropicStream accumulator fed the message_start/content_block_*/
    # message_delta events) is the next slice and reuses every transform here.
    class Anthropic < Base
      include SSE

      DEFAULT_MODEL = "claude-sonnet-4-5"
      DEFAULT_BASE_URL = "https://api.anthropic.com"
      DEFAULT_MAX_TOKENS = 4096
      # max_tokens is required by the Messages API, unlike OpenAI where it is
      # optional, so the provider always sends one.
      API_VERSION = "2023-06-01"

      attr_reader :model

      def initialize(api_key: ENV.fetch("ANTHROPIC_API_KEY", nil), model: DEFAULT_MODEL,
                     base_url: DEFAULT_BASE_URL, max_tokens: DEFAULT_MAX_TOKENS,
                     open_timeout: 15, read_timeout: 120)
        super()
        if api_key.nil? || api_key.empty?
          raise ArgumentError,
                "missing Anthropic API key (set ANTHROPIC_API_KEY or pass :api_key)"
        end

        @api_key = api_key
        @model = model
        @base_url = base_url.chomp("/")
        @max_tokens = max_tokens
        @open_timeout = open_timeout
        @read_timeout = read_timeout
      end

      def name
        "anthropic"
      end

      def chat(messages:, tools: [], model: nil, **options)
        request_model = model || @model
        max_tokens = options[:max_tokens] || @max_tokens
        payload = post("/v1/messages",
                       self.class.build_body(messages, tools, request_model, max_tokens, options))

        raw_stop = payload["stop_reason"]
        stop_reason, error_message = self.class.map_stop_reason(raw_stop, payload["stop_details"])
        response_model = payload["model"]
        Response.new(
          message: self.class.deserialize_message(payload["content"]),
          usage: Usage.from_anthropic(payload["usage"],
                                      pricing: Pricing.cost_for(response_model || request_model)),
          raw: payload,
          model: response_model,
          finish_reason: raw_stop,
          stop_reason: stop_reason,
          error_message: error_message
        )
      rescue Providers::Error => e
        error_response(e.message, model: request_model, retry_after_ms: e.retry_after_ms)
      end

      # Streaming counterpart to #chat. Opens an SSE request, decodes each
      # Messages stream event through an AnthropicStream accumulator, and yields
      # the ordered StreamEvents as content arrives. Returns the final
      # Truffle::Response once the stream closes, so a caller that ignores the
      # block still gets the whole turn. A transport or parse failure is folded
      # into the stream as an :error event (via the accumulator's #fail) rather
      # than raised, and the returned Response carries StopReason::ERROR.
      #
      # Pass signal: a Truffle::AbortSignal to cancel mid-stream. It is checked
      # between socket reads; on abort the reader stops and the turn folds into a
      # clean :done terminal with StopReason::ABORTED, carrying whatever content
      # arrived before the cancel. Reuses every wire transform from #chat: only
      # stream: true is added to the body and the decode runs event by event.
      def chat_stream(messages:, tools: [], model: nil, signal: nil, **options, &block)
        request_model = model || @model
        max_tokens = options[:max_tokens] || @max_tokens
        body = self.class.build_body(messages, tools, request_model, max_tokens, options)
        body[:stream] = true

        acc = AnthropicStream.new(pricing_model: request_model)
        drive_stream("/v1/messages", body, acc, signal: signal, &block)
      end

      # Build the Messages API request body. The system prompt is lifted out of
      # the message list into a top-level field (pi's context.systemPrompt), the
      # remaining messages are converted to Anthropic's role/content shape, and
      # max_tokens is always present because the API requires it.
      def self.build_body(messages, tools, model, max_tokens, options = {})
        system, conversation = extract_system(messages)
        body = {
          model: model,
          max_tokens: max_tokens,
          messages: convert_messages(conversation)
        }
        body[:system] = system unless system.empty?
        unless tools.empty?
          body[:tools] = convert_tools(tools)
          if (choice = options[:tool_choice])
            body[:tool_choice] = choice.is_a?(String) ? { type: choice } : choice
          end
        end
        body[:temperature] = options[:temperature] if options.key?(:temperature)
        body
      end

      # Split the system message(s) off the front of the history. Anthropic takes
      # the system prompt as a top-level field, not a message, so every :system
      # message is joined and returned separately from the rest.
      def self.extract_system(messages)
        system = messages.select { |m| m.role == :system }.map(&:text).compact.join("\n")
        rest = messages.reject { |m| m.role == :system }
        [system, rest]
      end

      # Convert Truffle messages (already system-stripped) into Anthropic
      # MessageParam hashes. User and assistant turns map directly; consecutive
      # :tool results are coalesced into a single user message carrying one
      # tool_result block each, matching pi's convertMessages.
      def self.convert_messages(messages)
        params = []
        index = 0
        while index < messages.length
          message = messages[index]
          case message.role
          when :user
            content = to_anthropic_content(message.content)
            params << { role: "user", content: content } unless empty_content?(content)
          when :assistant
            blocks = assistant_blocks(message)
            params << { role: "assistant", content: blocks } unless blocks.empty?
          when :tool
            results = [tool_result_block(message)]
            while index + 1 < messages.length && messages[index + 1].role == :tool
              index += 1
              results << tool_result_block(messages[index])
            end
            params << { role: "user", content: results }
          end
          index += 1
        end
        params
      end

      # The assistant turn's content blocks in Anthropic shape: text, thinking
      # (or redacted_thinking), and tool_use. Empty text and empty-signature
      # thinking are handled the way pi does: an empty text block is dropped, and
      # a thinking block with no signature is downgraded to plain text since
      # Anthropic rejects an unsigned thinking block on replay.
      def self.assistant_blocks(message)
        blocks = []
        message.content.each do |block|
          case block.type
          when :text
            blocks << { type: "text", text: block.text } unless block.text.strip.empty?
          when :thinking
            blocks.concat(thinking_blocks(block))
          when :tool_call
            blocks << { type: "tool_use", id: block.id, name: block.name,
                        input: block.arguments || {} }
          end
        end
        blocks
      end

      def self.thinking_blocks(block)
        return [{ type: "redacted_thinking", data: block.signature }] if block.redacted?
        return [] if block.thinking.strip.empty?

        if block.signature.nil? || block.signature.strip.empty?
          [{ type: "text", text: block.thinking }]
        else
          [{ type: "thinking", thinking: block.thinking, signature: block.signature }]
        end
      end

      # One tool_result block for a :tool message, linked back to the tool_use by
      # id. The result content follows the same text-or-blocks rule as any other
      # content (a placeholder text block stands in when only images are present).
      def self.tool_result_block(message)
        {
          type: "tool_result",
          tool_use_id: message.tool_call_id,
          content: to_anthropic_content(message.content, placeholder: true)
        }
      end

      # Render content blocks the way pi's convertContentBlocks does: a plain
      # joined string when there is no image, otherwise a block array of text and
      # base64 image sources. When placeholder is set (tool results), an
      # image-only result gets a leading "(see attached image)" text block, since
      # Anthropic needs at least one text block alongside images there.
      def self.to_anthropic_content(blocks, placeholder: false)
        texts = blocks.select { |b| b.type == :text }
        images = blocks.select { |b| b.type == :image }
        return texts.map(&:text).join("\n") if images.empty?

        out = []
        texts.each { |t| out << { type: "text", text: t.text } unless t.text.strip.empty? }
        images.each do |img|
          out << { type: "image",
                   source: { type: "base64", media_type: img.mime_type, data: img.data } }
        end
        if placeholder && out.none? do |b|
          b[:type] == "text"
        end
          out.unshift({ type: "text",
                        text: "(see attached image)" })
        end
        out
      end

      def self.empty_content?(content)
        content.is_a?(String) ? content.strip.empty? : content.empty?
      end

      # Convert provider-neutral tool schemas (Toolbox#to_schema) into Anthropic
      # tools: the JSON Schema lives under input_schema, not parameters.
      def self.convert_tools(tools)
        tools.map do |tool|
          schema = tool[:parameters] || {}
          {
            name: tool[:name],
            description: tool[:description],
            input_schema: {
              type: "object",
              properties: schema[:properties] || {},
              required: schema[:required] || []
            }
          }
        end
      end

      # Rebuild a Truffle assistant Message from an Anthropic content array. text
      # and thinking become content blocks; redacted_thinking keeps its opaque
      # data as the signature; tool_use becomes a ToolCall in the same list.
      def self.deserialize_message(content)
        blocks = []
        tool_calls = []
        Array(content).each do |item|
          case item["type"]
          when "text"
            blocks << Content::Text.new(text: item["text"].to_s)
          when "thinking"
            blocks << Content::Thinking.new(thinking: item["thinking"].to_s,
                                            signature: item["signature"])
          when "redacted_thinking"
            blocks << Content::Thinking.new(thinking: "[Reasoning redacted]",
                                            signature: item["data"], redacted: true)
          when "tool_use"
            tool_calls << ToolCall.new(id: item["id"], name: item["name"],
                                       arguments: item["input"] || {})
          end
        end
        Message.assistant(content: blocks, tool_calls: tool_calls)
      end

      # Map an Anthropic stop_reason onto a Truffle::StopReason plus an error
      # message when it signals a failure. A port of pi's mapStopReason:
      # end_turn / stop_sequence / pause_turn are a clean stop, max_tokens is a
      # length cutoff, tool_use is a tool pause, refusal carries the model's
      # explanation, and sensitive is a safety-filter error. pi throws on an
      # unknown reason; like the OpenAI port we fold it into an error carrying the
      # raw reason instead, which is the same net behavior pi's thrown error
      # produces (an error event), without crashing the loop.
      def self.map_stop_reason(reason, stop_details = nil)
        case reason
        when "end_turn", "stop_sequence", "pause_turn" then [StopReason::STOP, nil]
        when "max_tokens" then [StopReason::LENGTH, nil]
        when "tool_use" then [StopReason::TOOL_USE, nil]
        when "refusal"
          explanation = stop_details && (stop_details["explanation"] || stop_details[:explanation])
          [StopReason::ERROR, explanation || "The model refused to complete the request"]
        when "sensitive" then [StopReason::ERROR, "Content flagged by safety filters"]
        else [StopReason::ERROR, "Provider stop_reason: #{reason}"]
        end
      end

      private

      def post(path, body)
        uri = URI("#{@base_url}#{path}")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = @open_timeout
        http.read_timeout = @read_timeout

        request = Net::HTTP::Post.new(uri)
        request["x-api-key"] = @api_key
        request["anthropic-version"] = API_VERSION
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body)

        response = http.request(request)
        unless response.is_a?(Net::HTTPSuccess)
          raise Error.new("Anthropic #{response.code}: #{truncate(response.body)}",
                          retry_after_ms: retry_after_ms(response))
        end

        JSON.parse(response.body)
      rescue JSON::ParserError => e
        raise Error, "could not parse Anthropic response: #{e.message}"
      rescue Timeout::Error, IOError, SocketError, SystemCallError => e
        raise Error, "Anthropic request failed: #{e.class}: #{e.message}"
      end

      # Auth headers for the shared SSE transport (Providers::SSE#stream_post).
      def stream_request_headers
        { "x-api-key" => @api_key, "anthropic-version" => API_VERSION }
      end

      # Label the shared SSE transport puts on a non-success streaming response.
      def provider_label
        "Anthropic"
      end
    end
  end
end
