# frozen_string_literal: true

require_relative "test_helper"

# The cancellation token itself.
class TestAbortSignal < Minitest::Test
  def test_starts_live
    signal = Truffle::AbortSignal.new

    refute_predicate signal, :aborted?
    assert_nil signal.reason
  end

  def test_abort_flips_and_records_reason
    signal = Truffle::AbortSignal.new
    signal.abort("user pressed ctrl-c")

    assert_predicate signal, :aborted?
    assert_equal "user pressed ctrl-c", signal.reason
  end

  def test_abort_has_a_default_reason
    signal = Truffle::AbortSignal.new.abort

    assert_equal "aborted", signal.reason
  end

  def test_abort_is_idempotent_first_reason_wins
    signal = Truffle::AbortSignal.new
    signal.abort("first")
    signal.abort("second")

    assert_equal "first", signal.reason
  end

  def test_aborted_constructor
    signal = Truffle::AbortSignal.aborted("preempted")

    assert_predicate signal, :aborted?
    assert_equal "preempted", signal.reason
  end

  def test_abort_is_visible_across_threads
    signal = Truffle::AbortSignal.new
    Thread.new { signal.abort("from another thread") }.join

    assert_predicate signal, :aborted?
  end
end

# The agent loop honoring a signal at turn boundaries.
class TestAgentAbort < Minitest::Test
  def test_signal_aborted_before_run_makes_no_provider_call
    provider = StubProvider.new([StubProvider.text("never reached")])
    agent = Truffle::Agent.new(provider: provider)
    seen = nil
    agent.on(:agent_end) { |p| seen = p }

    result = agent.run("hello", signal: Truffle::AbortSignal.aborted)

    assert_empty provider.calls, "provider must not be called once already aborted"
    assert_nil result
    assert_equal Truffle::StopReason::ABORTED, seen[:stop_reason]
    assert_nil seen[:error_message]
  end

  def test_abort_after_a_tool_call_stops_before_the_next_turn
    # Turn 1 asks for a tool; the tool result handler trips the signal, so the
    # loop should end at the next boundary instead of requesting turn 2.
    signal = Truffle::AbortSignal.new
    provider = StubProvider.new([
                                  StubProvider.tool_call(id: "c1", name: "echo",
                                                         arguments: { "value" => "hi" }),
                                  StubProvider.text("should never run")
                                ])
    echo = Truffle::Tool.define("echo", "Echo a value") do
      param :value, :string, required: true
      run { |value:| value }
    end
    agent = Truffle::Agent.new(provider: provider, tools: [echo])

    ended = nil
    agent.on(:tool_result) { signal.abort("cancelled mid-run") }
    agent.on(:agent_end) { |p| ended = p }

    result = agent.run("echo hi", signal: signal)

    assert_equal 1, provider.calls.length, "second turn must not be requested after abort"
    assert_nil result
    assert_equal Truffle::StopReason::ABORTED, ended[:stop_reason]
    # The partial history (user, assistant tool call, tool result) is preserved.
    assert_equal %i[user assistant tool], ended[:messages].map(&:role)
  end

  def test_no_signal_runs_to_a_clean_finish
    provider = StubProvider.new([StubProvider.text("done", finish_reason: "stop")])
    agent = Truffle::Agent.new(provider: provider)
    ended = nil
    agent.on(:agent_end) { |p| ended = p }

    result = agent.run("hi")

    assert_equal "done", result
    assert_equal Truffle::StopReason::STOP, ended[:stop_reason]
  end
end
