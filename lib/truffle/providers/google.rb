# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module Truffle
  module Providers
    # Google Gemini provider over the Generative Language API with tool calling.
    #
    # Dependency-free like the OpenAI and Anthropic providers: it speaks the
    # generateContent endpoint directly with Net::HTTP and the stdlib JSON, no
    # @google/genai client gem. A port of the wire shapes in pi's
    # packages/ai/src/api/google-shared.ts and google-generative-ai.ts, the parts
    # that matter for a single non-streaming turn: the system prompt is a
    # top-level systemInstruction rather than a message, messages become Gemini
    # Content with role "user"/"model", tool calls are functionCall parts, tool
    # results are functionResponse parts coalesced into one user turn, tools carry
    # a parametersJsonSchema, and finish reasons and usage map onto Truffle's
    # normalized shapes.
    #
    # Both halves of pi's Google surface are here: the non-streaming #chat does a
    # single buffered generateContent request, and #chat_stream drives the
    # streamGenerateContent SSE endpoint through a GoogleStream accumulator over
    # the shared Providers::SSE transport, reusing every wire transform below.
    class Google < Base
      include SSE

      DEFAULT_MODEL = "gemini-2.5-flash"
      DEFAULT_BASE_URL = "https://generativelanguage.googleapis.com/v1beta"

      attr_reader :model

      def initialize(api_key: ENV.fetch("GEMINI_API_KEY", nil), model: DEFAULT_MODEL,
                     base_url: DEFAULT_BASE_URL, open_timeout: 15, read_timeout: 120)
        super()
        if api_key.nil? || api_key.empty?
          raise ArgumentError,
                "missing Gemini API key (set GEMINI_API_KEY or pass :api_key)"
        end

        @api_key = api_key
        @model = model
        @base_url = base_url.chomp("/")
        @open_timeout = open_timeout
        @read_timeout = read_timeout
      end

      def name
        "google"
      end

      def chat(messages:, tools: [], model: nil, **options)
        request_model = model || @model
        payload = post("/models/#{request_model}:generateContent",
                       self.class.build_body(messages, tools, options))

        candidate = Array(payload["candidates"]).first || {}
        message = self.class.deserialize_message(candidate["content"])
        raw_finish = candidate["finishReason"]
        stop_reason, error_message = self.class.map_stop_reason(raw_finish)
        # Gemini reports a plain STOP finish even when the turn is a tool call, so
        # override to tool_use when the model asked for one, the way pi does.
        if message.tool_calls?
          stop_reason = StopReason::TOOL_USE
          error_message = nil
        end

        response_model = payload["modelVersion"] || request_model
        Response.new(
          message: message,
          usage: Usage.from_google(payload["usageMetadata"],
                                   pricing: Pricing.cost_for(response_model)),
          raw: payload,
          model: response_model,
          finish_reason: raw_finish,
          stop_reason: stop_reason,
          error_message: error_message
        )
      rescue Providers::Error => e
        error_response(e.message, model: request_model, retry_after_ms: e.retry_after_ms)
      end

      # Streaming counterpart to #chat. Opens an SSE request to
      # streamGenerateContent (with ?alt=sse so the server emits Server-Sent
      # Events rather than a JSON array), decodes each chunk through a GoogleStream
      # accumulator, and yields the ordered StreamEvents as content arrives.
      # Returns the final Truffle::Response once the stream closes, so a caller
      # that ignores the block still gets the whole turn. A transport or parse
      # failure folds into the stream as an :error event (via the accumulator's
      # #fail) rather than raised, and the returned Response carries
      # StopReason::ERROR.
      #
      # Pass signal: a Truffle::AbortSignal to cancel mid-stream. It is checked
      # between socket reads; on abort the reader stops and the turn folds into a
      # clean :done terminal with StopReason::ABORTED, carrying whatever content
      # arrived before the cancel. Reuses every wire transform from #chat: only the
      # endpoint and the chunk-by-chunk decode differ.
      def chat_stream(messages:, tools: [], model: nil, signal: nil, **options, &block)
        request_model = model || @model
        body = self.class.build_body(messages, tools, options)
        path = "/models/#{request_model}:streamGenerateContent?alt=sse"

        acc = GoogleStream.new(pricing_model: request_model)
        drive_stream(path, body, acc, signal: signal, &block)
      end

      # Build the generateContent request body. The system prompt is lifted out of
      # the message list into a top-level systemInstruction (pi's
      # context.systemPrompt), the remaining messages convert to Gemini Content,
      # tools carry a parametersJsonSchema, and tool choice maps to a
      # functionCallingConfig mode. The model id rides in the URL, not the body.
      def self.build_body(messages, tools, options = {})
        system, conversation = extract_system(messages)
        body = { contents: convert_messages(conversation) }
        unless system.empty?
          body[:systemInstruction] = { parts: [{ text: Providers.sanitize_text(system) }] }
        end
        unless tools.empty?
          body[:tools] = convert_tools(tools)
          if (choice = options[:tool_choice])
            body[:toolConfig] = { functionCallingConfig: { mode: map_tool_choice(choice) } }
          end
        end
        gen = {}
        gen[:temperature] = options[:temperature] if options.key?(:temperature)
        gen[:maxOutputTokens] = options[:max_tokens] if options.key?(:max_tokens)
        apply_response_schema(gen, options)
        body[:generationConfig] = gen unless gen.empty?
        body
      end

      # Wire a structured-output request from a schema: option into Gemini's
      # generationConfig. Uses responseJsonSchema (full JSON Schema) rather than
      # responseSchema (the OpenAPI-3.0 subset) to match this file's
      # parametersJsonSchema tool precedent and the lowercase-typed Schema#to_h.
      # responseMimeType must be application/json for the schema to take effect.
      def self.apply_response_schema(gen, options)
        schema = options[:schema]
        return unless schema

        gen[:responseMimeType] = "application/json"
        gen[:responseJsonSchema] = Providers.schema_definition(schema)
      end

      # Split the system message(s) off the front of the history. Gemini takes the
      # system prompt as a top-level systemInstruction, not a message, so every
      # :system message is joined and returned separately from the rest.
      def self.extract_system(messages)
        system = messages.select { |m| m.role == :system }.map(&:text).compact.join("\n")
        rest = messages.reject { |m| m.role == :system }
        [system, rest]
      end

      # Convert Truffle messages (already system-stripped) into Gemini Content
      # hashes. User and assistant turns map directly (assistant becomes role
      # "model"); consecutive :tool results coalesce into a single user turn of
      # functionResponse parts, matching pi's convertMessages, which keeps all
      # function responses in one user turn for the API.
      def self.convert_messages(messages)
        contents = []
        messages.each do |message|
          case message.role
          when :user
            parts = user_parts(message.content)
            contents << { role: "user", parts: parts } unless parts.empty?
          when :assistant
            parts = model_parts(message)
            contents << { role: "model", parts: parts } unless parts.empty?
          when :tool
            append_function_response(contents, function_response_part(message))
          end
        end
        contents
      end

      # A user turn's parts: text becomes a text part, an image becomes inlineData
      # with its base64 payload and MIME type.
      def self.user_parts(blocks)
        blocks.filter_map do |block|
          case block.type
          when :text then { text: Providers.sanitize_text(block.text) }
          when :image then { inlineData: { mimeType: block.mime_type, data: block.data } }
          end
        end
      end

      # The assistant turn's parts in Gemini shape: text, thinking (kept as a
      # thought part only when it carries a valid base64 thought signature,
      # otherwise downgraded to a plain text part the way pi does for a
      # cross-model replay), and functionCall. Empty text and empty thinking are
      # dropped. A text part keeps its thought signature when one is present and
      # valid, so a later replay can carry the reasoning context Gemini expects.
      def self.model_parts(message)
        parts = []
        message.content.each do |block|
          case block.type
          when :text
            text = Providers.sanitize_text(block.text)
            next if text.strip.empty?

            part = { text: text }
            part[:thoughtSignature] = block.signature if valid_signature?(block.signature)
            parts << part
          when :thinking
            thinking = Providers.sanitize_text(block.thinking)
            next if thinking.strip.empty?

            parts << thinking_part(block, thinking)
          when :tool_call
            parts << { functionCall: { name: block.name, args: block.arguments || {} } }
          end
        end
        parts
      end

      def self.thinking_part(block, thinking = Providers.sanitize_text(block.thinking))
        if valid_signature?(block.signature)
          { thought: true, text: thinking, thoughtSignature: block.signature }
        else
          # Gemini rejects a thought part without a valid signature on replay, so
          # an unsigned (or foreign-model) thinking block becomes plain text.
          { text: thinking }
        end
      end

      # One functionResponse part for a :tool message, linked to the call by name.
      # The text of the result is joined and sent under the "output" key, matching
      # the SDK's success shape. Images in a tool result are not yet forwarded;
      # that is a later refinement (Gemini 3+ multimodal function responses).
      def self.function_response_part(message)
        {
          functionResponse: {
            name: message.name.to_s,
            response: { output: tool_result_text(message.content) }
          }
        }
      end

      # Append a functionResponse to the contents. Gemini wants every function
      # response in one user turn, so when the last turn is already a user turn of
      # function responses the part is merged into it rather than opening a new
      # turn, the way pi's convertMessages does.
      def self.append_function_response(contents, part)
        last = contents.last
        if last && last[:role] == "user" && last[:parts].any? { |p| p.key?(:functionResponse) }
          last[:parts] << part
        else
          contents << { role: "user", parts: [part] }
        end
      end

      def self.tool_result_text(blocks)
        blocks.select { |b| b.type == :text }
              .map { |block| Providers.sanitize_text(block.text) }
              .join("\n")
      end

      # Convert provider-neutral tool schemas (Toolbox#to_schema) into Gemini
      # function declarations under a single tools entry. The JSON Schema lives
      # under parametersJsonSchema (pi's default, which supports full JSON Schema)
      # rather than the OpenAPI-subset parameters field.
      def self.convert_tools(tools)
        return [] if tools.empty?

        [{
          functionDeclarations: tools.map do |tool|
            schema = tool[:parameters] || {}
            {
              name: tool[:name],
              description: tool[:description],
              parametersJsonSchema: {
                type: "object",
                properties: schema[:properties] || {},
                required: schema[:required] || []
              }
            }
          end
        }]
      end

      # Map a tool choice string onto a Gemini FunctionCallingConfigMode. A port of
      # pi's mapToolChoice: auto/none/any, anything else falls back to AUTO.
      def self.map_tool_choice(choice)
        case choice.to_s
        when "none" then "NONE"
        when "any" then "ANY"
        else "AUTO"
        end
      end

      # Rebuild a Truffle assistant Message from a Gemini candidate content hash.
      # text parts become Text blocks (or Thinking blocks when flagged as a
      # thought), and functionCall parts become ToolCalls in the same list. Gemini
      # rarely returns a call id over REST, so a deterministic one is synthesized
      # from the function name and its position, enough to link the result back.
      def self.deserialize_message(content)
        parts = (content && content["parts"]) || []
        blocks = []
        tool_calls = []
        parts.each_with_index do |part, index|
          if part.key?("functionCall")
            call = part["functionCall"] || {}
            tool_calls << ToolCall.new(id: call["id"] || "#{call["name"]}-#{index}",
                                       name: call["name"], arguments: call["args"] || {})
          elsif part.key?("text")
            blocks << text_block(part)
          end
        end
        Message.assistant(content: blocks, tool_calls: tool_calls)
      end

      def self.text_block(part)
        signature = part["thoughtSignature"]
        if part["thought"]
          Content::Thinking.new(thinking: part["text"].to_s, signature: signature)
        else
          Content::Text.new(text: part["text"].to_s, signature: signature)
        end
      end

      # Map a Gemini finishReason string onto a Truffle::StopReason plus an error
      # message when it signals a failure. A port of pi's mapStopReasonString: STOP
      # (or a missing reason) is a clean stop, MAX_TOKENS is a length cutoff, and
      # everything else (SAFETY, RECITATION, PROHIBITED_CONTENT, ...) folds into an
      # error carrying the raw reason rather than crashing the loop.
      def self.map_stop_reason(reason)
        case reason
        when nil, "STOP" then [StopReason::STOP, nil]
        when "MAX_TOKENS" then [StopReason::LENGTH, nil]
        else [StopReason::ERROR, "Provider finishReason: #{reason}"]
        end
      end

      # Thought signatures must be valid base64 for the Google API (a TYPE_BYTES
      # field). A port of pi's isValidThoughtSignature: non-empty, length a
      # multiple of four, and only base64 characters.
      def self.valid_signature?(signature)
        return false if signature.nil? || signature.empty?
        return false unless (signature.length % 4).zero?

        signature.match?(%r{\A[A-Za-z0-9+/]+={0,2}\z})
      end

      private

      def post(path, body)
        uri = URI("#{@base_url}#{path}")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = @open_timeout
        http.read_timeout = @read_timeout

        request = Net::HTTP::Post.new(uri)
        request["x-goog-api-key"] = @api_key
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body)

        response = http.request(request)
        unless response.is_a?(Net::HTTPSuccess)
          raise Error.new("Google #{response.code}: #{truncate(response.body)}",
                          retry_after_ms: retry_after_ms(response))
        end

        JSON.parse(response.body)
      rescue JSON::ParserError => e
        raise Error, "could not parse Google response: #{e.message}"
      rescue Timeout::Error, IOError, SocketError, SystemCallError => e
        raise Error, "Google request failed: #{e.class}: #{e.message}"
      end

      def truncate(str, limit = 500)
        s = str.to_s
        s.length > limit ? "#{s[0, limit]}..." : s
      end

      # Auth header for the shared SSE transport (Providers::SSE#stream_post).
      def stream_request_headers(**)
        { "x-goog-api-key" => @api_key }
      end

      # Label the shared SSE transport puts on a non-success streaming response.
      def provider_label
        "Google"
      end
    end
  end
end
