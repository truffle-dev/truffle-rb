# frozen_string_literal: true

require "test_helper"
require "timeout"

# Ports pi's parallel tool-call execution contract: a turn's tool calls preflight
# in source order, allowed tool bodies run concurrently by default, and the tool
# result messages appended to history stay in assistant source order.
class TestAgentParallelToolExecution < Minitest::Test
  def two_call_provider
    StubProvider.new([
                       Truffle::Response.new(
                         message: Truffle::Message.assistant(
                           tool_calls: [
                             Truffle::ToolCall.new(
                               id: "c1", name: "slow", arguments: { "value" => "first" }
                             ),
                             Truffle::ToolCall.new(
                               id: "c2", name: "fast", arguments: { "value" => "second" }
                             )
                           ]
                         ),
                         finish_reason: "tool_calls",
                         stop_reason: Truffle::StopReason::TOOL_USE
                       ),
                       StubProvider.text("done")
                     ])
  end

  def build_tools(slow_mode: :parallel)
    slow_started = Queue.new
    slow_done = Queue.new
    parallel_observed = false

    slow = Truffle::Tool.define("slow", "Slow echo", execution_mode: slow_mode) do
      param :value, :string, required: true
      run do |value:|
        slow_started << true
        sleep 0.05
        slow_done << true
        "slow:#{value}"
      end
    end

    fast = Truffle::Tool.define("fast", "Fast echo") do
      param :value, :string, required: true
      run do |value:|
        begin
          Timeout.timeout(0.02) { slow_started.pop }
          parallel_observed = slow_done.empty?
        rescue Timeout::Error
          parallel_observed = false
        end
        "fast:#{value}"
      end
    end

    [slow, fast, -> { parallel_observed }]
  end

  def tool_messages(agent)
    agent.messages.select { |message| message.role == :tool }
  end

  def test_default_parallel_execution_runs_tool_bodies_concurrently
    slow, fast, parallel_observed = build_tools
    agent = Truffle::Agent.new(provider: two_call_provider, tools: [slow, fast])

    agent.run("run both")

    assert parallel_observed.call, "fast should run while slow is still active"
    assert_equal %w[c1 c2], tool_messages(agent).map(&:tool_call_id)
    assert_equal ["slow:first", "fast:second"], tool_messages(agent).map(&:text)
  end

  def test_agent_can_force_sequential_tool_execution
    slow, fast, parallel_observed = build_tools
    agent = Truffle::Agent.new(provider: two_call_provider, tools: [slow, fast],
                               tool_execution: :sequential)

    agent.run("run both")

    refute parallel_observed.call, "sequential mode should run one tool at a time"
    assert_equal %w[c1 c2], tool_messages(agent).map(&:tool_call_id)
    assert_equal ["slow:first", "fast:second"], tool_messages(agent).map(&:text)
  end

  def test_facade_forwards_tool_execution_mode
    agent = Truffle.agent(provider: StubProvider.new([StubProvider.text("done")]),
                          tool_execution: :sequential)

    assert_equal :sequential, agent.tool_execution
  end

  def test_agent_rejects_unknown_tool_execution_mode
    error = assert_raises(ArgumentError) do
      Truffle::Agent.new(provider: StubProvider.new([]), tool_execution: :sideways)
    end

    assert_match(/unknown tool execution mode :sideways/, error.message)
  end

  def test_agent_rejects_nil_tool_execution_mode
    error = assert_raises(ArgumentError) do
      Truffle::Agent.new(provider: StubProvider.new([]), tool_execution: nil)
    end

    assert_match(/unknown tool execution mode nil/, error.message)
  end

  def test_sequential_tool_forces_whole_batch_to_run_sequentially
    slow, fast, parallel_observed = build_tools(slow_mode: :sequential)
    agent = Truffle::Agent.new(provider: two_call_provider, tools: [slow, fast])

    agent.run("run both")

    refute parallel_observed.call, "a sequential tool should force the batch to run sequentially"
    assert_equal %w[c1 c2], tool_messages(agent).map(&:tool_call_id)
  end

  def test_before_hooks_preflight_all_calls_before_any_tool_runs
    calls = []
    slow, fast, = build_tools
    before = lambda do |tool_call:, **|
      calls << "before:#{tool_call.name}"
      nil
    end
    after = lambda do |tool_call:, result:, **|
      calls << "after:#{tool_call.name}"
      { result: result }
    end

    [slow, fast].each do |tool|
      original = tool.handler
      tool.instance_variable_set(:@handler, lambda { |**kwargs|
        calls << "run:#{tool.name}"
        original.call(**kwargs)
      })
    end

    agent = Truffle::Agent.new(provider: two_call_provider, tools: [slow, fast],
                               before_tool_call: before, after_tool_call: after)
    agent.run("run both")

    assert_equal ["before:slow", "before:fast"], calls.first(2)
    assert_includes calls, "run:slow"
    assert_includes calls, "run:fast"
  end
end
