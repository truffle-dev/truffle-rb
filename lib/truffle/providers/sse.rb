# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module Truffle
  module Providers
    # Shared Server-Sent Events transport for the streaming providers. The OpenAI
    # and Anthropic providers open an identical streaming POST and decode it the
    # same way; only the auth headers and the error label differ, which the host
    # class supplies through #stream_request_headers and #provider_label. The
    # decode is tolerant for both wire formats: only "data:" records carry
    # payload, the OpenAI "[DONE]" sentinel is dropped (Anthropic never sends
    # one), and a record that fails to parse is skipped rather than aborting the
    # stream. The host class provides @base_url, @open_timeout, and @read_timeout.
    module SSE
      # Drive an accumulator through a streaming POST: feed each decoded object to
      # the accumulator, then close it with #finish, #abort, or #fail depending on
      # how the stream ended, yielding every StreamEvent the accumulator emits.
      # Returns the accumulator's final #response, so a caller that ignores the
      # block still gets the whole turn. A pre-tripped signal aborts before the
      # request opens; a transport or parse failure folds into the stream as the
      # accumulator's #fail rather than raising. The accumulator must respond to
      # #feed, #finish, #abort, #fail, and #response (both stream classes do).
      def drive_stream(path, body, acc, signal: nil, headers: nil, &block)
        emit = ->(event) { block&.call(event) }
        if signal&.aborted?
          acc.abort(&emit)
          return acc.response
        end

        begin
          stopped = stream_post(path, body, signal: signal, headers: headers) do |frame|
            acc.feed(frame, &emit)
          end
          stopped == :aborted ? acc.abort(&emit) : acc.finish(&emit)
        rescue StandardError => e
          acc.fail(e, &emit)
        end
        acc.response
      end

      # Open a streaming POST and yield each decoded JSON object as it arrives.
      # Reads the body in fragments, buffers a partial trailing line across reads,
      # and parses each complete data line. A non-success status is raised as
      # Error before any object is yielded.
      #
      # If signal aborts, stop reading at the next fragment boundary and return
      # :aborted so the caller can fold a clean cancellation into the stream.
      # Otherwise returns nil. The check is cooperative (between fragments), not a
      # forced socket close, so a stalled read still waits up to read_timeout.
      def stream_post(path, body, signal: nil, headers: nil, &block)
        uri = URI("#{@base_url}#{path}")
        http = build_http(uri)
        request = build_stream_request(uri, body, headers: headers)

        aborted = false
        http.request(request) do |response|
          unless response.is_a?(Net::HTTPSuccess)
            raise Error, "#{provider_label} #{response.code}: #{truncate(response.read_body)}"
          end

          aborted = read_sse_body(response, signal, &block)
        end
        aborted ? :aborted : nil
      end

      private

      def build_http(uri)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = @open_timeout
        http.read_timeout = @read_timeout
        http
      end

      def build_stream_request(uri, body, headers: nil)
        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request["Accept"] = "text/event-stream"
        # Net::HTTP silently requests gzip and its inflater buffers the whole
        # compressed stream, delivering the "live" events in one burst at the
        # end. Identity keeps SSE fragments arriving as the provider sends them.
        request["Accept-Encoding"] = "identity"
        stream_request_headers(headers: headers).each { |key, value| request[key] = value }
        request.body = JSON.generate(body)
        request
      end

      # Pull fragments off the socket, split on newlines, and decode each complete
      # SSE line. Returns true if the signal cancelled mid-stream, false if the
      # body drained on its own.
      def read_sse_body(response, signal, &block)
        buffer = +""
        aborted = false
        response.read_body do |fragment|
          if signal&.aborted?
            aborted = true
            break
          end
          buffer << fragment
          while (newline = buffer.index("\n"))
            line = buffer.slice!(0, newline + 1)
            handle_sse_line(line.chomp, &block)
          end
        end
        handle_sse_line(buffer.chomp, &block) unless aborted || buffer.empty?
        aborted
      end

      # Decode one SSE line. Only "data:" records carry payload; the OpenAI
      # terminal sentinel "data: [DONE]" is dropped (Anthropic never sends one),
      # and "event:", "id:", comment (":"), and blank separator lines are ignored.
      # A record that fails to parse is skipped rather than aborting the stream.
      def handle_sse_line(line)
        return if line.empty?
        return unless line.start_with?("data:")

        data = line.delete_prefix("data:").strip
        return if data.empty? || data == "[DONE]"

        decoded = JSON.parse(data)
        yield decoded if decoded.is_a?(Hash)
      rescue JSON::ParserError
        nil
      end

      def truncate(str, limit = 500)
        s = str.to_s
        s.length > limit ? "#{s[0, limit]}..." : s
      end
    end
  end
end
