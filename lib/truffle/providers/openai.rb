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
      DEFAULT_MODEL = "gpt-4o-mini"
      DEFAULT_BASE_URL = "https://api.openai.com/v1"

      attr_reader :model

      def initialize(api_key: ENV["OPENAI_API_KEY"], model: DEFAULT_MODEL,
                     base_url: DEFAULT_BASE_URL, open_timeout: 15, read_timeout: 120)
        super()
        raise ArgumentError, "missing OpenAI API key (set OPENAI_API_KEY or pass :api_key)" if api_key.nil? || api_key.empty?

        @api_key = api_key
        @model = model
        @base_url = base_url.chomp("/")
        @open_timeout = open_timeout
        @read_timeout = read_timeout
      end

      def name
        "openai"
      end

      def chat(messages:, tools: [], model: nil, **options)
        body = {
          model: model || @model,
          messages: serialize_messages(messages)
        }
        unless tools.empty?
          body[:tools] = tools.map { |t| { type: "function", function: t } }
          body[:tool_choice] = options.fetch(:tool_choice, "auto")
        end
        body[:temperature] = options[:temperature] if options.key?(:temperature)
        body[:max_tokens] = options[:max_tokens] if options.key?(:max_tokens)

        payload = post("/chat/completions", body)
        choice = payload.fetch("choices").first
        finish_reason = choice["finish_reason"]
        stop_reason, error_message = self.class.map_stop_reason(finish_reason)
        Response.new(
          message: deserialize_message(choice.fetch("message")),
          usage: payload["usage"] || {},
          raw: payload,
          model: payload["model"],
          finish_reason: finish_reason,
          stop_reason: stop_reason,
          error_message: error_message
        )
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
            { role: m.role.to_s, content: m.text.to_s }
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
          raise Error, "OpenAI #{response.code}: #{truncate(response.body)}"
        end

        JSON.parse(response.body)
      rescue JSON::ParserError => e
        raise Error, "could not parse OpenAI response: #{e.message}"
      end

      def truncate(str, limit = 500)
        s = str.to_s
        s.length > limit ? "#{s[0, limit]}..." : s
      end
    end
  end
end
