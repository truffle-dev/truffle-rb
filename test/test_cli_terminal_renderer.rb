# frozen_string_literal: true

require "test_helper"
require "stringio"

class TerminalRendererAgent
  def initialize
    @listeners = Hash.new { |hash, key| hash[key] = [] }
  end

  def on(event, &block)
    @listeners[event] << block
    self
  end

  def emit(event, payload)
    @listeners[event].each { |listener| listener.call(payload) }
  end
end

class TestCLITerminalRenderer < Minitest::Test
  def setup
    @out = StringIO.new
    @err = StringIO.new
    @renderer = Truffle::CLI::TerminalRenderer.new(out: @out, err: @err)
  end

  def event(type, **fields)
    Truffle::StreamEvent.new(type: type, **fields)
  end

  def assistant_response(text, stop_reason: Truffle::StopReason::STOP, error_message: nil)
    Truffle::Response.new(
      message: Truffle::Message.assistant(content: text),
      stop_reason: stop_reason,
      error_message: error_message
    )
  end

  def test_streams_each_text_block_once
    @renderer.start_turn
    @renderer.stream(event(:text_start, content_index: 0))
    @renderer.stream(event(:text_delta, content_index: 0, delta: "first"))
    @renderer.stream(event(:text_end, content_index: 0, content: "first"))
    @renderer.stream(event(:text_start, content_index: 1))
    @renderer.stream(event(:text_end, content_index: 1, content: ""))
    @renderer.stream(event(:text_start, content_index: 2))
    @renderer.stream(event(:text_delta, content_index: 2, delta: "second"))
    @renderer.stream(event(:text_end, content_index: 2, content: "second"))

    status = @renderer.finish(assistant_response("firstsecond"))

    assert_equal 0, status
    assert_equal "first\nsecond\n", @out.string
    assert_empty @err.string
  end

  def test_renders_thinking_and_tool_lifecycle_on_stderr
    agent = TerminalRendererAgent.new
    @renderer.attach(agent)
    @renderer.start_turn

    @renderer.stream(event(:thinking_start, content_index: 0))
    @renderer.stream(event(:thinking_delta, content_index: 0, delta: "check facts"))
    @renderer.stream(event(:thinking_end, content_index: 0, content: "check facts"))
    call = Truffle::ToolCall.new(
      id: "call-1", name: "read", arguments: { "path" => "README.md" }
    )
    agent.emit(:tool_call, call: call)
    agent.emit(:tool_result, call: call, result: "alpha\nbeta")

    assert_equal 0, @renderer.finish(assistant_response("done"))
    assert_equal "done\n", @out.string
    assert_equal(
      "thinking> check facts\n" \
      "tool> read {\"path\":\"README.md\"}\n" \
      "tool< read: alpha beta\n",
      @err.string
    )
  end

  def test_renders_redacted_thinking_when_no_delta_arrives
    @renderer.start_turn
    @renderer.stream(event(:thinking_start, content_index: 0))
    @renderer.stream(
      event(:thinking_end, content_index: 0, content: "[Reasoning redacted]")
    )
    @renderer.finish(assistant_response(""))

    assert_equal "thinking> [Reasoning redacted]\n", @err.string
  end

  def test_reports_retry_and_compaction_status
    agent = TerminalRendererAgent.new
    @renderer.attach(agent)
    @renderer.start_turn

    agent.emit(
      :retry,
      attempt: 1, max_retries: 3, delay_ms: 250, error_message: "overloaded"
    )
    agent.emit(:compaction, result: Object.new)
    agent.emit(:compaction, result: nil, error: RuntimeError.new("summary failed"))
    @renderer.finish(assistant_response(""))

    assert_equal(
      "retry> 1/3 in 250ms: overloaded\n" \
      "compaction> complete\n" \
      "compaction> failed: summary failed\n",
      @err.string
    )
  end

  def test_falls_back_to_the_final_response_without_text_deltas
    @renderer.start_turn

    assert_equal 0, @renderer.finish(assistant_response("buffered"))
    assert_equal "buffered\n", @out.string
  end

  def test_partial_text_and_failure_are_not_duplicated
    @renderer.start_turn
    @renderer.stream(event(:text_delta, content_index: 0, delta: "partial"))

    status = @renderer.finish(
      assistant_response(
        "partial",
        stop_reason: Truffle::StopReason::ERROR,
        error_message: "provider failed"
      )
    )

    assert_equal 1, status
    assert_equal "partial\n", @out.string
    assert_equal "provider failed\n", @err.string
  end

  def test_tool_previews_are_bounded
    agent = TerminalRendererAgent.new
    @renderer.attach(agent)
    @renderer.start_turn
    call = Truffle::ToolCall.new(
      id: "call-1", name: "write", arguments: { "content" => "x" * 2_000 }
    )

    agent.emit(:tool_call, call: call)
    agent.emit(:tool_result, call: call, result: "y" * 2_000)
    @renderer.finish(assistant_response(""))

    assert_operator @err.string.lines[0].length, :<=, 540
    assert_operator @err.string.lines[1].length, :<=, 540
    assert_includes @err.string, "..."
  end
end
