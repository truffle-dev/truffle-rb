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

  def chat(messages:, tools: [], model: nil, **_options)
    @calls << { messages: messages.map(&:to_h), tools: tools, model: model }
    raise "StubProvider ran out of scripted responses" if @script.empty?

    @script.shift
  end

  # Helper to build a tool-call response.
  def self.tool_call(id:, name:, arguments:)
    Truffle::Response.new(
      message: Truffle::Message.assistant(
        tool_calls: [Truffle::ToolCall.new(id: id, name: name, arguments: arguments)]
      ),
      finish_reason: "tool_calls"
    )
  end

  # Helper to build a plain text response.
  def self.text(content)
    Truffle::Response.new(
      message: Truffle::Message.assistant(content: content),
      finish_reason: "stop"
    )
  end
end
