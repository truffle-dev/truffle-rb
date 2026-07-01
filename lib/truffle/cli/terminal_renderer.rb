# frozen_string_literal: true

require "json"

module Truffle
  module CLI
    # Renders one streamed agent turn for a line-oriented terminal. Assistant
    # text stays on stdout so shell callers can capture it; reasoning, tool
    # activity, retries, and compaction status go to stderr.
    class TerminalRenderer
      PREVIEW_CHARS = 500

      def initialize(out: $stdout, err: $stderr)
        @out = out
        @err = err
        @attached_agent = nil
        start_turn
      end

      def attach(agent)
        return self if @attached_agent.equal?(agent)

        @attached_agent = agent
        agent.on(:tool_call) { |payload| render_tool_call(payload[:call]) }
        agent.on(:tool_result) do |payload|
          render_tool_result(payload[:call], payload[:result])
        end
        agent.on(:retry) { |payload| render_retry(payload) }
        agent.on(:compaction) { |payload| render_compaction(payload) }
        self
      end

      def start_turn
        @wrote_text = false
        @text_block_wrote = false
        @thinking_open = false
        @thinking_wrote = false
        self
      end

      def stream(event)
        case event.type
        when :text_start
          finish_text_block
          finish_thinking
        when :text_delta
          finish_thinking
          render_text_delta(event.delta)
        when :text_end
          finish_text_block
        when :thinking_start
          finish_text_block
          finish_thinking
          @thinking_open = true
        when :thinking_delta
          render_thinking_delta(event.delta)
        when :thinking_end
          finish_thinking(event.content)
        end
        self
      end

      def finish(response)
        finish_text_block
        finish_thinking
        if response && PRINT_FAILURE_STOP_REASONS.include?(response.stop_reason)
          return CLI.render_print_text(response, out: @out, err: @err)
        end
        return 0 if @wrote_text

        CLI.render_print_text(response, out: @out, err: @err)
      end

      private

      def render_text_delta(delta)
        text = delta.to_s
        return if text.empty?

        write(@out, text)
        @text_block_wrote = true
        @wrote_text = true
      end

      def finish_text_block
        return unless @text_block_wrote

        write(@out, "\n")
        @text_block_wrote = false
      end

      def render_thinking_delta(delta)
        text = delta.to_s
        return if text.empty?

        @thinking_open = true
        unless @thinking_wrote
          write(@err, "thinking> ")
          @thinking_wrote = true
        end
        write(@err, text)
      end

      def finish_thinking(content = nil)
        if @thinking_wrote
          write(@err, "\n")
        elsif @thinking_open && !content.to_s.empty?
          write(@err, "thinking> #{content}\n")
        end
        @thinking_open = false
        @thinking_wrote = false
      end

      def render_tool_call(call)
        return unless call

        finish_live_blocks
        arguments = call.arguments
        suffix =
          if arguments.respond_to?(:empty?) && arguments.empty?
            ""
          else
            " #{preview(json(arguments))}"
          end
        write(@err, "tool> #{call.name}#{suffix}\n")
      end

      def render_tool_result(call, result)
        return unless call

        finish_live_blocks
        value = preview(result)
        value = "(empty)" if value.empty?
        write(@err, "tool< #{call.name}: #{value}\n")
      end

      def render_retry(payload)
        finish_live_blocks
        attempt = "#{payload[:attempt]}/#{payload[:max_retries]}"
        delay = payload[:delay_ms].to_i
        message = payload[:error_message].to_s
        suffix = message.empty? ? "" : ": #{preview(message)}"
        write(@err, "retry> #{attempt} in #{delay}ms#{suffix}\n")
      end

      def render_compaction(payload)
        finish_live_blocks
        if payload[:error]
          write(@err, "compaction> failed: #{preview(payload[:error].message)}\n")
        elsif payload[:result]
          write(@err, "compaction> complete\n")
        else
          write(@err, "compaction> skipped\n")
        end
      end

      def finish_live_blocks
        finish_text_block
        finish_thinking
      end

      def json(value)
        JSON.generate(value)
      rescue JSON::GeneratorError, TypeError
        value.inspect
      end

      def preview(value)
        text = value.to_s.scrub.gsub(/\s+/, " ").strip
        return text if text.length <= PREVIEW_CHARS

        "#{text.slice(0, PREVIEW_CHARS)}..."
      end

      def write(stream, text)
        stream.write(text)
        stream.flush if stream.respond_to?(:flush)
      end
    end

    module_function

    def terminal_streaming?(agent, out, disabled: false)
      return false if disabled
      return false unless out.respond_to?(:tty?) && out.tty?
      return false unless agent.respond_to?(:run_stream)
      return true unless agent.respond_to?(:provider)

      provider = agent.provider
      return provider.respond_to?(:chat_stream) unless provider.is_a?(Providers::Base)

      provider.method(:chat_stream).owner != Providers::Base
    end

    # Signal handlers cannot safely enter AbortSignal's Monitor. The trap only
    # flips a local flag; a short-lived watcher performs the actual abort from a
    # normal Ruby thread, then the previous handler is restored before returning.
    def with_interrupt_abort(signal)
      interrupted = false
      done = false
      begin
        previous = Signal.trap("INT") { interrupted = true }
      rescue ArgumentError
        return yield
      end

      watcher = Thread.new do
        loop do
          break if done

          if interrupted
            signal.abort("interrupted")
            break
          end
          sleep 0.01
        end
      end
      watcher.report_on_exception = false if watcher.respond_to?(:report_on_exception=)
      yield
    ensure
      done = true
      watcher&.join
      Signal.trap("INT", previous) if previous
    end

    private_class_method :terminal_streaming?, :with_interrupt_abort
  end
end
