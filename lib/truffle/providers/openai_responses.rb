# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module Truffle
  module Providers
    # OpenAI Responses API provider with tool calling and reasoning round-trips.
    #
    # Dependency-free like the other providers: it speaks POST /v1/responses
    # directly with Net::HTTP and the stdlib JSON. A port of the wire shapes in
    # pi's packages/ai/src/api/openai-responses.ts: the conversation is an
    # `input` array of typed items (messages, reasoning, function_call,
    # function_call_output) and the model's turn comes back as an `output`
    # array of the same item kinds. The item conversions themselves live in
    # OpenAIResponsesShared, mirroring pi's openai-responses-shared.ts, because
    # the stream accumulator speaks the same vocabulary.
    #
    # Truffle owns the session, so every request runs the API statelessly:
    # `store: false` plus `include: ["reasoning.encrypted_content"]`, with prior
    # reasoning items replayed verbatim in the next request's input instead of
    # `previous_response_id`. A reasoning output item round-trips as a
    # Content::Thinking block whose signature holds the whole item as JSON
    # (id, summary, and encrypted_content included), the way anthropic.rb keeps
    # a thinking block's signature; a message item's id and phase round-trip on
    # the Text block signature. Assistant items labeled phase "commentary" are
    # visible preambles between tool calls and stay ordinary text.
    class OpenAIResponses < Base
      include SSE

      DEFAULT_MODEL = "gpt-5.5"
      DEFAULT_BASE_URL = "https://api.openai.com/v1"

      attr_reader :model, :base_url

      # reasoning: is the request's reasoning config, passed through as given
      # ({ effort: "high" }, { effort: "low", summary: "detailed" }, ...). When
      # a config names no summary, summary: "auto" is added so reasoning
      # summaries stream as thinking events by default. nil sends no reasoning
      # field and leaves the model on its own defaults.
      def initialize(api_key: ENV.fetch("OPENAI_API_KEY", nil), model: DEFAULT_MODEL,
                     base_url: DEFAULT_BASE_URL, reasoning: nil,
                     open_timeout: 15, read_timeout: 120)
        super()
        if api_key.nil? || api_key.empty?
          raise ArgumentError,
                "missing OpenAI API key (set OPENAI_API_KEY or pass :api_key)"
        end

        @api_key = api_key
        @model = model
        @base_url = base_url.chomp("/")
        @reasoning = reasoning
        @open_timeout = open_timeout
        @read_timeout = read_timeout
      end

      def name
        "openai_responses"
      end

      def chat(messages:, tools: [], model: nil, **options)
        request_model = model || @model
        payload = post("/responses",
                       self.class.build_body(messages, tools, request_model,
                                             merge_reasoning(options)))

        message = OpenAIResponsesShared.deserialize_message(payload["output"])
        stop_reason, error_message = OpenAIResponsesShared.map_stop_reason(
          payload["status"],
          incomplete_reason: payload.dig("incomplete_details", "reason"),
          error: payload["error"]
        )
        stop_reason = StopReason::TOOL_USE if stop_reason == StopReason::STOP &&
                                              message.tool_calls?
        response_model = payload["model"]
        Response.new(
          message: message,
          usage: Usage.from_openai_responses(payload["usage"],
                                             pricing: Pricing.cost_for(response_model ||
                                                                       request_model)),
          raw: payload,
          model: response_model,
          finish_reason: payload["status"],
          stop_reason: stop_reason,
          error_message: error_message
        )
      rescue Providers::Error => e
        error_response(e.message, model: request_model, retry_after_ms: e.retry_after_ms)
      end

      # Streaming counterpart to #chat. Opens an SSE request, decodes each typed
      # Responses stream event through an OpenAIResponsesStream accumulator, and
      # yields the ordered StreamEvents as content arrives. Returns the final
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
        body = self.class.build_body(messages, tools, request_model, merge_reasoning(options))
        body[:stream] = true

        acc = OpenAIResponsesStream.new(pricing_model: request_model)
        drive_stream("/responses", body, acc, signal: signal, &block)
      end

      # Build the Responses API request body. Every request is stateless: the
      # session lives in Truffle, so store: false keeps the server from keeping
      # one too, and include: reasoning.encrypted_content asks for the opaque
      # reasoning payload the next request replays.
      def self.build_body(messages, tools, model, options = {})
        body = {
          model: model,
          input: OpenAIResponsesShared.convert_messages(messages),
          store: false,
          include: ["reasoning.encrypted_content"]
        }
        if (config = reasoning_config(options[:reasoning]))
          body[:reasoning] = config
        end
        unless tools.empty?
          body[:tools] = OpenAIResponsesShared.convert_tools(tools)
          body[:tool_choice] = options[:tool_choice] if options[:tool_choice]
        end
        body[:temperature] = options[:temperature] if options.key?(:temperature)
        limit = options[:max_output_tokens] || options[:max_tokens]
        body[:max_output_tokens] = limit if limit
        apply_text_format(body, options)
        body
      end

      # A reasoning config with summary defaulted to "auto" when the caller set
      # an effort but named no summarizer, matching pi: summaries are what map
      # onto Truffle's thinking events, so asking for reasoning without them
      # would stream nothing visible. An explicit summary (nil included) wins.
      def self.reasoning_config(config)
        return nil unless config.is_a?(Hash)
        return config if config.key?(:summary) || config.key?("summary")

        config.merge(summary: "auto")
      end

      # Wire a structured-output request from a schema: option into the
      # Responses text.format field, the flattened twin of Chat Completions'
      # response_format.json_schema. strict is opt-in and defaults off, because
      # strict mode also demands additionalProperties:false and every property
      # in required, which is the caller's schema to satisfy.
      def self.apply_text_format(body, options)
        schema = options[:schema]
        return unless schema

        body[:text] = {
          format: {
            type: "json_schema",
            name: options.fetch(:schema_name, "response"),
            schema: Providers.schema_definition(schema),
            strict: options.fetch(:strict, false)
          }
        }
      end

      private

      # Fold the constructor's reasoning config into a call's options. An
      # explicit reasoning: in the call (nil included) wins over the default.
      def merge_reasoning(options)
        return options if @reasoning.nil? || options.key?(:reasoning)

        options.merge(reasoning: @reasoning)
      end

      def post(path, body)
        uri = URI("#{@base_url}#{path}")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = @open_timeout
        http.read_timeout = @read_timeout

        request = Net::HTTP::Post.new(uri)
        request["Authorization"] = "Bearer #{@api_key}"
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body)

        response = http.request(request)
        unless response.is_a?(Net::HTTPSuccess)
          raise Error.new("OpenAI Responses #{response.code}: #{truncate(response.body)}",
                          retry_after_ms: retry_after_ms(response))
        end

        JSON.parse(response.body)
      rescue JSON::ParserError => e
        raise Error, "could not parse OpenAI Responses response: #{e.message}"
      rescue Timeout::Error, IOError, SocketError, SystemCallError => e
        raise Error, "OpenAI Responses request failed: #{e.class}: #{e.message}"
      end

      # Auth header for the shared SSE transport (Providers::SSE#stream_post).
      def stream_request_headers(**)
        { "Authorization" => "Bearer #{@api_key}" }
      end

      # Label the shared SSE transport puts on a non-success streaming response.
      def provider_label
        "OpenAI Responses"
      end
    end
  end
end
