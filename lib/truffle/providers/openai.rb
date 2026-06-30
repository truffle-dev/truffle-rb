# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module Truffle
  module Providers
    # OpenAI Chat Completions provider with tool calling.
    #
    # Deliberately dependency-free: it speaks the HTTP API directly with
    # Net::HTTP and the stdlib JSON, so a fresh Ruby can run Truffle with nothing
    # but `gem install truffle`. It also works against any OpenAI-compatible
    # endpoint (Ollama, vLLM, Together, OpenRouter, ...) by passing :base_url.
    class OpenAI < Base
      include SSE

      DEFAULT_MODEL = "gpt-4o-mini"
      DEFAULT_BASE_URL = "https://api.openai.com/v1"

      attr_reader :model, :base_url

      def initialize(api_key: ENV.fetch("OPENAI_API_KEY", nil), model: DEFAULT_MODEL,
                     base_url: DEFAULT_BASE_URL, open_timeout: 15, read_timeout: 120,
                     provider_name: "openai", headers: nil, auth_header: true,
                     model_headers: nil)
        super()
        if auth_header && (api_key.nil? || api_key.empty?)
          raise ArgumentError,
                "missing OpenAI API key (set OPENAI_API_KEY or pass :api_key)"
        end

        @api_key = api_key
        @model = model
        @base_url = base_url.chomp("/")
        @provider_name = provider_name.to_s
        @headers = normalize_headers(headers)
        @model_headers = normalize_model_headers(model_headers)
        @auth_header = auth_header
        @open_timeout = open_timeout
        @read_timeout = read_timeout
      end

      def name
        @provider_name
      end

      def chat(messages:, tools: [], model: nil, **options)
        request_model = model || @model
        payload = post(
          "/chat/completions",
          build_chat_body(messages, tools, request_model, options),
          headers: model_headers_for(request_model)
        )
        choice = payload.fetch("choices").first
        finish_reason = choice["finish_reason"]
        stop_reason, error_message = self.class.map_stop_reason(finish_reason)
        response_model = payload["model"]
        Response.new(
          message: deserialize_message(choice.fetch("message")),
          usage: Usage.parse(payload["usage"],
                             pricing: Pricing.cost_for(response_model || request_model)),
          raw: payload,
          model: response_model,
          finish_reason: finish_reason,
          stop_reason: stop_reason,
          error_message: error_message
        )
      rescue Providers::Error => e
        error_response(e.message, model: request_model, retry_after_ms: e.retry_after_ms)
      end

      # Streaming counterpart to #chat. Opens an SSE request, decodes each chunk
      # through an OpenAIStream accumulator, and yields the ordered StreamEvents
      # as content arrives. Returns the final Truffle::Response once the stream
      # closes, so a caller that ignores the block still gets the whole turn.
      # A transport or parse failure is folded into the stream as an :error event
      # (via the accumulator's #fail) rather than raised, mirroring pi's catch
      # path; the returned Response then carries StopReason::ERROR.
      #
      # Pass signal: a Truffle::AbortSignal to cancel mid-stream. It is checked
      # between socket reads; on abort the reader stops and the turn folds into a
      # clean :done terminal with StopReason::ABORTED (not an :error), carrying
      # whatever content arrived before the cancel.
      def chat_stream(messages:, tools: [], model: nil, signal: nil, **options, &block)
        request_model = model || @model
        body = build_chat_body(messages, tools, request_model, options)
        body[:stream] = true
        body[:stream_options] = { include_usage: true }

        acc = OpenAIStream.new(pricing_model: request_model)
        drive_stream("/chat/completions", body, acc,
                     signal: signal, headers: model_headers_for(request_model), &block)
      end

      # Map an OpenAI Chat Completions finish_reason onto a Truffle::StopReason,
      # plus an error message when the reason signals a failure. A faithful port
      # of pi's mapStopReason in packages/ai/src/api/openai-completions.ts: a null
      # reason means a clean stop, "end" is an alias for "stop", both the legacy
      # "function_call" and current "tool_calls" mean a tool pause, and anything
      # else is treated as an error carrying the raw reason. Returns
      # [stop_reason, error_message]; error_message is nil unless it is an error.
      def self.map_stop_reason(reason)
        case reason
        when nil, "stop", "end" then [StopReason::STOP, nil]
        when "length" then [StopReason::LENGTH, nil]
        when "function_call", "tool_calls" then [StopReason::TOOL_USE, nil]
        when "content_filter" then [StopReason::ERROR, "Provider finish_reason: content_filter"]
        when "network_error" then [StopReason::ERROR, "Provider finish_reason: network_error"]
        else [StopReason::ERROR, "Provider finish_reason: #{reason}"]
        end
      end

      private

      # Build the shared Chat Completions request body for both #chat and
      # #chat_stream. The streaming path adds :stream and :stream_options on top.
      def build_chat_body(messages, tools, model, options)
        body = {
          model: model || @model,
          messages: serialize_messages(messages)
        }
        unless tools.empty?
          body[:tools] = tools.map { |t| { type: "function", function: t } }
          body[:tool_choice] = options.fetch(:tool_choice, "auto")
        end
        body[:temperature] = options[:temperature] if options.key?(:temperature)
        apply_token_limit(body, model, options)
        body
      end

      def apply_token_limit(body, model, options)
        if options.key?(:max_completion_tokens)
          body[:max_completion_tokens] = options[:max_completion_tokens]
        elsif options.key?(:max_tokens)
          key = max_completion_tokens_field?(model) ? :max_completion_tokens : :max_tokens
          body[key] = options[:max_tokens]
        end
      end

      def max_completion_tokens_field?(model)
        native_openai_endpoint? &&
          (catalog_model = Models.find(model.to_s)) &&
          catalog_model.provider == :openai &&
          catalog_model.reasoning?
      end

      def native_openai_endpoint?
        @provider_name == "openai" && URI(@base_url).host == "api.openai.com"
      rescue URI::InvalidURIError
        false
      end

      def serialize_messages(messages)
        messages.map do |m|
          case m.role
          when :assistant
            h = { role: "assistant", content: m.text }
            unless m.tool_calls.empty?
              h[:tool_calls] = m.tool_calls.map do |tc|
                {
                  id: tc.id,
                  type: "function",
                  function: { name: tc.name, arguments: JSON.generate(tc.arguments) }
                }
              end
            end
            h
          when :tool
            { role: "tool", tool_call_id: m.tool_call_id, content: m.text.to_s }
          else
            { role: m.role.to_s, content: serialize_user_content(m) }
          end
        end
      end

      def serialize_user_content(message)
        return message.text.to_s unless message.content.any?(Content::Image)

        message.content.filter_map do |block|
          case block
          when Content::Text
            next if block.text.empty?

            { type: "text", text: block.text }
          when Content::Image
            { type: "image_url",
              image_url: { url: "data:#{block.mime_type};base64,#{block.data}" } }
          end
        end
      end

      def deserialize_message(raw)
        tool_calls = Array(raw["tool_calls"]).map do |tc|
          fn = tc["function"] || {}
          ToolCall.new(
            id: tc["id"],
            name: fn["name"],
            arguments: parse_arguments(fn["arguments"])
          )
        end
        Message.assistant(content: raw["content"], tool_calls: tool_calls)
      end

      def parse_arguments(raw)
        return {} if raw.nil? || raw == ""

        JSON.parse(raw)
      rescue JSON::ParserError
        # A model very occasionally emits malformed JSON for arguments. Surface
        # the raw string under a sentinel key rather than crashing the loop.
        { "_raw" => raw }
      end

      def post(path, body, headers: nil)
        uri = URI("#{@base_url}#{path}")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = @open_timeout
        http.read_timeout = @read_timeout

        request = Net::HTTP::Post.new(uri)
        request_headers(headers: headers).each { |key, value| request[key] = value }
        request.body = JSON.generate(body)

        response = http.request(request)
        unless response.is_a?(Net::HTTPSuccess)
          raise Error.new("OpenAI #{response.code}: #{truncate(response.body)}",
                          retry_after_ms: retry_after_ms(response))
        end

        JSON.parse(response.body)
      rescue JSON::ParserError => e
        raise Error, "could not parse OpenAI response: #{e.message}"
      rescue Timeout::Error, IOError, SocketError, SystemCallError => e
        raise Error, "OpenAI request failed: #{e.class}: #{e.message}"
      end

      # Auth header for the shared SSE transport (Providers::SSE#stream_post).
      def stream_request_headers(headers: nil)
        provider_headers(headers: headers)
      end

      # Label the shared SSE transport puts on a non-success streaming response.
      def provider_label
        "OpenAI"
      end

      def request_headers(headers: nil)
        { "Content-Type" => "application/json" }.merge(provider_headers(headers: headers))
      end

      def provider_headers(headers: nil)
        merged = @headers.merge(normalize_headers(headers))
        merged["Authorization"] = "Bearer #{@api_key}" if @auth_header
        merged
      end

      def model_headers_for(model)
        @model_headers.fetch(model.to_s, {})
      end

      def normalize_headers(headers)
        return {} unless headers.respond_to?(:each)

        headers.each_with_object({}) do |(key, value), normalized|
          next if key.nil? || value.nil?

          normalized[key.to_s] = value.to_s
        end
      end

      def normalize_model_headers(model_headers)
        return {} unless model_headers.respond_to?(:each)

        model_headers.each_with_object({}) do |(model, headers), normalized|
          next if model.nil?

          values = normalize_headers(headers)
          normalized[model.to_s] = values unless values.empty?
        end
      end
    end
  end
end
