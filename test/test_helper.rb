# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "truffle"

# A deterministic provider for unit tests. You hand it a script of responses
# (one per chat call); it returns them in order. This lets us exercise the agent
# loop, tool execution, and event emission with zero network calls.
class StubProvider < Truffle::Providers::Base
  attr_reader :calls

  def initialize(script)
    super()
    @script = script.dup
    @calls = []
  end

  def name
    "stub"
  end

  def chat(messages:, tools: [], model: nil, **options)
    @calls << { messages: messages.map(&:to_h), tools: tools, model: model, options: options }
    raise "StubProvider ran out of scripted responses" if @script.empty?

    @script.shift
  end

  # Helper to build a tool-call response. Pass usage: to exercise aggregation.
  def self.tool_call(id:, name:, arguments:, usage: nil)
    Truffle::Response.new(
      message: Truffle::Message.assistant(
        tool_calls: [Truffle::ToolCall.new(id: id, name: name, arguments: arguments)]
      ),
      usage: usage,
      finish_reason: "tool_calls",
      stop_reason: Truffle::StopReason::TOOL_USE
    )
  end

  # Helper to build a plain text response. Pass finish_reason: "length" (or any
  # other raw reason) to drive the stop-reason mapping in a test, or usage: a
  # Truffle::Usage to drive cross-turn cost aggregation.
  def self.text(content, finish_reason: "stop", usage: nil)
    stop_reason, error_message = Truffle::Providers::OpenAI.map_stop_reason(finish_reason)
    Truffle::Response.new(
      message: Truffle::Message.assistant(content: content),
      usage: usage,
      finish_reason: finish_reason,
      stop_reason: stop_reason,
      error_message: error_message
    )
  end
end
