# frozen_string_literal: true

require "test_helper"

# Exercises the before_tool_call / after_tool_call middleware seam on the agent
# loop (a port of pi's beforeToolCall / afterToolCall hooks). The before hook can
# veto a call before it runs; the after hook can override the executed result.
# A hook is handed a context Hash by keyword (:tool_call, :args, :messages, plus
# :result for the after hook); it declares the keys it reads and ignores the rest
# with **.
class TestAgentToolMiddleware < Minitest::Test
  def setup
    @echo = Truffle::Tool.define("echo", "Echo back the message") do
      param :message, :string, required: true
      run { |message:| message }
    end
  end

  def call_then_text(name:, arguments:, text: "done")
    StubProvider.new([
                       StubProvider.tool_call(id: "c1", name: name, arguments: arguments),
                       StubProvider.text(text)
                     ])
  end

  def tool_result(agent)
    agent.messages.find { |m| m.role == :tool }&.text
  end

  # A before hook that returns { block: true } stops the tool from running and the
  # reason becomes the tool result the model reads.
  def test_before_hook_block_prevents_execution_and_carries_reason
    ran = false
    tracking = Truffle::Tool.define("track", "Set a flag") do
      run do
        ran = true
        "executed"
      end
    end

    provider = call_then_text(name: "track", arguments: {})
    before = ->(tool_call:, **) { { block: true, reason: "not allowed: #{tool_call.name}" } }
    agent = Truffle::Agent.new(provider: provider, tools: [tracking], before_tool_call: before)

    agent.run("go")

    refute ran, "the tool body must not run when the before hook blocks"
    assert_equal "not allowed: track", tool_result(agent)
  end

  # A block with no :reason falls back to the default blocked message.
  def test_before_hook_block_uses_default_reason_when_omitted
    provider = call_then_text(name: "echo", arguments: { "message" => "hi" })
    before = ->(**) { { block: true } }
    agent = Truffle::Agent.new(provider: provider, tools: [@echo], before_tool_call: before)

    agent.run("go")

    assert_equal "Tool execution was blocked", tool_result(agent)
  end

  # A before hook that returns nil lets the call run normally, and it sees the
  # call, the parsed arguments, and the running messages.
  def test_before_hook_proceeds_and_receives_context
    seen = nil
    provider = call_then_text(name: "echo", arguments: { "message" => "hi" })
    before = lambda do |tool_call:, args:, messages:|
      seen = { name: tool_call.name, args: args, has_messages: messages.is_a?(Array) }
      nil
    end
    agent = Truffle::Agent.new(provider: provider, tools: [@echo], before_tool_call: before)

    agent.run("go")

    assert_equal "hi", tool_result(agent)
    assert_equal "echo", seen[:name]
    assert_equal({ "message" => "hi" }, seen[:args])
    assert seen[:has_messages]
  end

  # An after hook that returns { result: ... } replaces the tool result string.
  def test_after_hook_overrides_result
    provider = call_then_text(name: "echo", arguments: { "message" => "secret" })
    after = ->(**) { { result: "[redacted]" } }
    agent = Truffle::Agent.new(provider: provider, tools: [@echo], after_tool_call: after)

    agent.run("go")

    assert_equal "[redacted]", tool_result(agent)
  end

  # The after hook sees the executed result before any override.
  def test_after_hook_receives_executed_result
    seen = nil
    provider = call_then_text(name: "echo", arguments: { "message" => "hi" })
    after = lambda do |result:, **|
      seen = result
      nil
    end
    agent = Truffle::Agent.new(provider: provider, tools: [@echo], after_tool_call: after)

    agent.run("go")

    assert_equal "hi", seen
    assert_equal "hi", tool_result(agent), "returning nil keeps the original result"
  end

  # An after hook that returns a hash without :result keeps the original result.
  def test_after_hook_without_result_key_keeps_original
    provider = call_then_text(name: "echo", arguments: { "message" => "hi" })
    after = ->(**) { { unrelated: true } }
    agent = Truffle::Agent.new(provider: provider, tools: [@echo], after_tool_call: after)

    agent.run("go")

    assert_equal "hi", tool_result(agent)
  end

  # A hook that raises becomes an error result rather than killing the loop.
  def test_after_hook_raise_becomes_error_result
    provider = call_then_text(name: "echo", arguments: { "message" => "hi" })
    after = ->(**) { raise "hook boom" }
    agent = Truffle::Agent.new(provider: provider, tools: [@echo], after_tool_call: after)

    agent.run("go")

    assert_match(/Error in after_tool_call for 'echo'/, tool_result(agent))
    assert_match(/hook boom/, tool_result(agent))
  end

  # With no hooks supplied the loop behaves exactly as before.
  def test_no_hooks_leaves_default_behavior_unchanged
    provider = call_then_text(name: "echo", arguments: { "message" => "plain" })
    agent = Truffle::Agent.new(provider: provider, tools: [@echo])

    agent.run("go")

    assert_equal "plain", tool_result(agent)
  end

  # An unknown tool is reported immediately, before either hook runs.
  def test_unknown_tool_skips_both_hooks
    before_ran = false
    after_ran = false
    provider = call_then_text(name: "ghost", arguments: {})
    before = lambda do |**|
      before_ran = true
      nil
    end
    after = lambda do |**|
      after_ran = true
      nil
    end
    agent = Truffle::Agent.new(provider: provider, tools: [@echo],
                               before_tool_call: before, after_tool_call: after)

    agent.run("go")

    refute before_ran, "before hook must not run for an unknown tool"
    refute after_ran, "after hook must not run for an unknown tool"
    assert_equal "Error: unknown tool 'ghost'", tool_result(agent)
  end
end
