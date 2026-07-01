# frozen_string_literal: true

require "test_helper"

class StreamingStubProvider < Truffle::Providers::Base
  attr_reader :calls

  def initialize(script)
    super()
    @script = script.dup
    @calls = []
  end

  def name = "streaming-stub"

  def chat(messages:, tools: [], model: nil, **options)
    raise "unexpected non-streaming chat: #{[messages, tools, model, options].inspect}"
  end

  def chat_stream(messages:, tools: [], model: nil, signal: nil, **_options)
    @calls << { messages: messages.map(&:to_h), tools: tools, model: model, signal: signal }
    raise "StreamingStubProvider ran out of scripted responses" if @script.empty?

    @script.shift.call(signal) { |event| yield event if block_given? }
  end

  def self.text(text, chunks: [text], stop_reason: Truffle::StopReason::STOP)
    lambda do |_signal, &emit|
      emit.call(Truffle::StreamEvent.new(type: :start))
      emit.call(Truffle::StreamEvent.new(type: :text_start, content_index: 0))
      chunks.each do |chunk|
        emit.call(Truffle::StreamEvent.new(type: :text_delta, content_index: 0, delta: chunk))
      end
      emit.call(Truffle::StreamEvent.new(type: :text_end, content_index: 0, content: text))
      message = Truffle::Message.assistant(content: text)
      emit.call(Truffle::StreamEvent.new(type: :done, reason: stop_reason, message: message))

      Truffle::Response.new(message: message, stop_reason: stop_reason)
    end
  end

  def self.tool_call(id:, name:, arguments:, argument_chunks:)
    lambda do |_signal, &emit|
      emit.call(Truffle::StreamEvent.new(type: :start))
      emit.call(Truffle::StreamEvent.new(type: :toolcall_start, content_index: 0))
      argument_chunks.each do |chunk|
        emit.call(Truffle::StreamEvent.new(type: :toolcall_delta, content_index: 0,
                                           delta: chunk))
      end
      call = Truffle::ToolCall.new(id: id, name: name, arguments: arguments)
      emit.call(Truffle::StreamEvent.new(type: :toolcall_end, content_index: 0,
                                         tool_call: call))
      message = Truffle::Message.assistant(tool_calls: [call])
      emit.call(Truffle::StreamEvent.new(type: :done, reason: Truffle::StopReason::TOOL_USE,
                                         message: message))

      Truffle::Response.new(message: message, stop_reason: Truffle::StopReason::TOOL_USE)
    end
  end

  def self.abort_after_text(text)
    lambda do |signal, &emit|
      emit.call(Truffle::StreamEvent.new(type: :start))
      emit.call(Truffle::StreamEvent.new(type: :text_start, content_index: 0))
      emit.call(Truffle::StreamEvent.new(type: :text_delta, content_index: 0, delta: text))
      signal&.abort("test stop")
      emit.call(Truffle::StreamEvent.new(type: :text_end, content_index: 0, content: text))
      message = Truffle::Message.assistant(content: text)
      emit.call(Truffle::StreamEvent.new(type: :done, reason: Truffle::StopReason::ABORTED,
                                         message: message))

      Truffle::Response.new(message: message, stop_reason: Truffle::StopReason::ABORTED)
    end
  end
end

class TestAgentStreaming < Minitest::Test
  def setup
    @add = Truffle::Tool.define("add", "Add two integers") do
      param :a, :integer, required: true
      param :b, :integer, required: true
      run { |a:, b:| a + b }
    end
  end

  def test_run_stream_yields_text_deltas_and_returns_final_text
    provider = StreamingStubProvider.new([
                                           StreamingStubProvider.text(
                                             "hello", chunks: %w[he ll o]
                                           )
                                         ])
    agent = Truffle::Agent.new(provider: provider)
    events = []

    result = agent.run_stream("say hi") { |event| events << event }

    assert_equal "hello", result
    assert_equal %w[he ll o], events.select { |event| event.type == :text_delta }.map(&:delta)
    assert_equal %i[start text_start text_delta text_delta text_delta text_end done],
                 events.map(&:type)
    assert_equal "hello", agent.messages.last.text
  end

  def test_run_stream_emits_stream_events_to_agent_listeners
    provider = StreamingStubProvider.new([StreamingStubProvider.text("ok")])
    agent = Truffle::Agent.new(provider: provider)
    observed = []

    agent.on(:stream) { |payload| observed << payload.fetch(:event).type }
    agent.run_stream("stream")

    assert_equal %i[start text_start text_delta text_end done], observed
  end

  def test_run_stream_handles_streamed_tool_call_then_final_text
    provider = StreamingStubProvider.new([
                                           StreamingStubProvider.tool_call(
                                             id: "call_1", name: "add",
                                             arguments: { "a" => 2, "b" => 3 },
                                             argument_chunks: ["{\"a\":", "2,\"b\":3}"]
                                           ),
                                           StreamingStubProvider.text("The answer is 5.")
                                         ])
    agent = Truffle::Agent.new(provider: provider, tools: [@add])
    events = []

    result = agent.run_stream("What is 2 + 3?") { |event| events << event }

    assert_equal "The answer is 5.", result
    assert_equal 2, provider.calls.length
    assert_equal %i[start toolcall_start toolcall_delta toolcall_delta toolcall_end done
                    start text_start text_delta text_end done],
                 events.map(&:type)

    tool_message = agent.messages.find { |message| message.role == :tool }

    assert_equal "5", tool_message.text
  end

  def test_run_stream_can_abort_mid_stream
    signal = Truffle::AbortSignal.new
    provider = StreamingStubProvider.new([StreamingStubProvider.abort_after_text("partial")])
    agent = Truffle::Agent.new(provider: provider)
    ended = nil
    events = []

    agent.on(:agent_end) { |payload| ended = payload }
    result = agent.run_stream("start", signal: signal) { |event| events << event }

    assert_equal "partial", result
    assert_predicate signal, :aborted?
    assert_equal Truffle::StopReason::ABORTED, ended[:stop_reason]
    assert_equal Truffle::StopReason::ABORTED, events.last.reason
    assert_equal "partial", agent.messages.last.text
  end
end
