# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# A session-backed agent recovers from context overflow: a failed turn whose
# prompt exceeded the window is compacted away and retried once on the smaller
# context. A second consecutive overflow, a completed answer that overran the
# window, and a non-session agent each take a different, tested path.
class TestAgentOverflowRecovery < Minitest::Test
  # A 200_000-token window (threshold 183_616), so a 190_000-input usage sits
  # over the window for the silent-overflow path.
  MODEL = "claude-opus-4-5"

  def setup
    @noop = Truffle::Tool.define("noop", "A tool that does nothing") do
      run { "done" }
    end
  end

  def session(dir)
    Truffle::Session.create(dir: dir, cwd: dir)
  end

  # An error turn whose message names a known overflow phrase. This is what a
  # provider returns from #chat when the request overran the window.
  def overflow_error
    Truffle::Response.new(
      message: Truffle::Message.assistant(content: nil),
      stop_reason: Truffle::StopReason::ERROR,
      error_message: "Anthropic 400: prompt is too long: 250000 tokens"
    )
  end

  # A completed answer whose reported input already exceeds the window: the
  # silent-overflow case (provider accepted the oversized request).
  def silent_overflow(text)
    Truffle::Response.new(
      message: Truffle::Message.assistant(content: text),
      stop_reason: Truffle::StopReason::STOP,
      usage: Truffle::Usage.new(input: 250_000)
    )
  end

  # Build a session-backed agent over a scripted compacting provider.
  def agent_over(dir, script, **opts)
    provider = CompactingStub.new(script)
    agent = Truffle::Agent.new(provider: provider, model: MODEL, tools: [@noop],
                               session: session(dir), **opts)
    [agent, provider]
  end

  def test_overflow_error_is_compacted_and_the_turn_is_retried
    Dir.mktmpdir("truffle-overflow") do |dir|
      # Turn 1 builds history (so there is something to compact); turn 2 overflows;
      # the retry (turn 3) answers cleanly.
      agent, provider = agent_over(dir, [
                                     StubProvider.tool_call(id: "c1", name: "noop", arguments: {}),
                                     overflow_error,
                                     StubProvider.text("Recovered after compaction.")
                                   ])

      result = agent.run("start")

      # The loop ran three times: the tool turn, the overflowed turn, and the
      # retry. The summarizer ran once and a compaction entry was written.
      assert_equal 3, provider.loop_calls.size
      assert_equal 1, provider.summary_calls.size
      assert(agent.session.entries.any? { |e| e[:type] == "compaction" })
      assert_equal "Recovered after compaction.", result
    end
  end

  def test_the_failed_turn_is_dropped_from_the_retry_context
    Dir.mktmpdir("truffle-overflow") do |dir|
      agent, provider = agent_over(dir, [
                                     StubProvider.tool_call(id: "c1", name: "noop", arguments: {}),
                                     overflow_error,
                                     StubProvider.text("Recovered.")
                                   ])

      agent.run("start")

      # The retry's context (the third loop call) must not end on the failed
      # empty assistant turn: a trailing assistant message would make the
      # provider continue an empty answer.
      retry_messages = provider.loop_calls.last[:messages]

      refute_equal "assistant", retry_messages.last[:role].to_s
    end
  end

  def test_a_second_consecutive_overflow_ends_the_run_without_looping
    Dir.mktmpdir("truffle-overflow") do |dir|
      # Every loop call overflows. Recovery fires once; the second overflow is
      # unrecoverable, so the run ends rather than looping forever.
      agent, provider = agent_over(dir, [
                                     StubProvider.tool_call(id: "c1", name: "noop", arguments: {}),
                                     overflow_error,
                                     overflow_error
                                   ])
      errors = []
      agent.on(:compaction) { |p| errors << p[:error] if p[:error] }

      stop_reason = nil
      agent.on(:agent_end) { |p| stop_reason = p[:stop_reason] }
      agent.run("start")

      # Three calls total: tool turn, first overflow (retried), second overflow
      # (gives up). Not a fourth.
      assert_equal 3, provider.loop_calls.size
      assert_equal Truffle::StopReason::ERROR, stop_reason
      assert(errors.any? { |e| e.kind == :overflow_unrecovered })
    end
  end

  def test_a_completed_answer_over_the_window_compacts_but_does_not_retry
    Dir.mktmpdir("truffle-overflow") do |dir|
      # One turn whose answer is complete (stop) but whose input overran the
      # window. It compacts for hygiene but the answer is final: no retry.
      agent, provider = agent_over(dir, [
                                     StubProvider.tool_call(id: "c1", name: "noop", arguments: {}),
                                     silent_overflow("Final answer despite the overrun.")
                                   ])

      result = agent.run("start")

      assert_equal 2, provider.loop_calls.size
      assert_equal 1, provider.summary_calls.size
      assert_equal "Final answer despite the overrun.", result
    end
  end

  def test_overflow_recovery_is_off_without_a_session
    # A non-session agent has nowhere to compact, so an overflow error surfaces
    # as a terminal error turn with no retry.
    provider = StubProvider.new([overflow_error])
    agent = Truffle::Agent.new(provider: provider, model: MODEL, tools: [@noop])
    stop_reason = nil
    agent.on(:agent_end) { |p| stop_reason = p[:stop_reason] }

    agent.run("start")

    assert_equal 1, provider.calls.size
    assert_equal Truffle::StopReason::ERROR, stop_reason
  end

  def test_overflow_recovery_is_off_when_auto_compact_is_false
    Dir.mktmpdir("truffle-overflow") do |dir|
      agent, provider = agent_over(dir, [overflow_error], auto_compact: false)
      stop_reason = nil
      agent.on(:agent_end) { |p| stop_reason = p[:stop_reason] }

      agent.run("start")

      assert_equal 1, provider.loop_calls.size
      assert_empty provider.summary_calls
      assert_equal Truffle::StopReason::ERROR, stop_reason
    end
  end
end
