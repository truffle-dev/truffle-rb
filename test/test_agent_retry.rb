# frozen_string_literal: true

require "test_helper"

# The agent auto-retries a turn that failed with a transient provider or
# transport error: it drops the failed turn, waits an exponential backoff, and
# runs the turn again, bounded by a retry budget. A non-retryable error, a spent
# budget, and a disabled policy each take a different, tested path. Backoff is
# tuned to zero (or a tiny base) here so the suite never actually sleeps long.
class TestAgentRetry < Minitest::Test
  # A transient error turn, the shape a provider's #chat returns when the call
  # faltered: an empty assistant message with an ERROR stop and the failure text.
  def transient_error(message = "503 Service Unavailable")
    Truffle::Response.new(
      message: Truffle::Message.assistant(content: nil),
      stop_reason: Truffle::StopReason::ERROR,
      error_message: message
    )
  end

  def agent_over(script, **settings)
    provider = StubProvider.new(script)
    retry_settings = { enabled: true, max_retries: 3, base_delay_ms: 0 }.merge(settings)
    agent = Truffle::Agent.new(provider: provider, retry_settings: retry_settings)
    [agent, provider]
  end

  def test_a_transient_error_is_retried_and_then_succeeds
    agent, provider = agent_over([transient_error, StubProvider.text("Recovered.")])
    retries = []
    agent.on(:retry) { |p| retries << p }

    result = agent.run("go")

    assert_equal "Recovered.", result
    assert_equal 2, provider.calls.size
    assert_equal([1], retries.map { |r| r[:attempt] })
  end

  def test_the_failed_turn_is_dropped_from_the_retry_context
    agent, provider = agent_over([transient_error, StubProvider.text("ok")])

    agent.run("go")

    # The retry's context (the second call) must not end on the failed empty
    # assistant turn, or the provider would be asked to continue an empty answer.
    retry_messages = provider.calls.last[:messages]

    refute_equal "assistant", retry_messages.last[:role].to_s
  end

  def test_retries_are_bounded_by_the_budget
    # Every call errors. With a budget of two, the loop runs three times (the
    # first failure plus two retries) and then ends on the error rather than
    # looping forever.
    agent, provider = agent_over([transient_error, transient_error, transient_error],
                                 max_retries: 2)
    retries = []
    agent.on(:retry) { |p| retries << p }
    stop_reason = nil
    agent.on(:agent_end) { |p| stop_reason = p[:stop_reason] }

    agent.run("go")

    assert_equal 3, provider.calls.size
    assert_equal([1, 2], retries.map { |r| r[:attempt] })
    assert_equal Truffle::StopReason::ERROR, stop_reason
  end

  def test_the_backoff_grows_exponentially
    # delay_ms must follow base * 2**(attempt - 1): 1, 2, 4 from a 1ms base.
    agent, provider = agent_over([transient_error, transient_error, transient_error,
                                  transient_error],
                                 max_retries: 3, base_delay_ms: 1)
    delays = []
    agent.on(:retry) { |p| delays << p[:delay_ms] }

    agent.run("go")

    assert_equal 4, provider.calls.size
    assert_equal [1, 2, 4], delays
  end

  def test_a_non_retryable_error_is_not_retried
    agent, provider = agent_over([transient_error("billing hard limit reached")])
    retried = false
    agent.on(:retry) { retried = true }
    stop_reason = nil
    agent.on(:agent_end) { |p| stop_reason = p[:stop_reason] }

    agent.run("go")

    assert_equal 1, provider.calls.size
    refute retried
    assert_equal Truffle::StopReason::ERROR, stop_reason
  end

  def test_a_context_overflow_error_is_not_retried_here
    # An overflow message that also carries a retryable token ("503") must not be
    # retried: overflow is the compactor's job, not the retry policy's. The retry
    # path classifies it as overflow and declines, even though "503" alone would
    # otherwise look transient.
    agent, provider = agent_over([transient_error("503 error: context_length_exceeded")])
    retried = false
    agent.on(:retry) { retried = true }

    agent.run("go")

    assert_equal 1, provider.calls.size
    refute retried
  end

  def test_a_disabled_policy_does_not_retry
    agent, provider = agent_over([transient_error], enabled: false)
    retried = false
    agent.on(:retry) { retried = true }

    agent.run("go")

    assert_equal 1, provider.calls.size
    refute retried
  end

  def test_the_attempt_counter_resets_after_a_turn_that_is_not_retried
    # Budget of one. A first transient error is retried; a tool turn resets the
    # counter; a second transient error in the same run is retried again on its
    # own fresh budget, so the final answer is reached. Without the reset, the
    # second error would exceed the spent budget and end the run early.
    noop = Truffle::Tool.define("noop", "does nothing") { run { "done" } }
    provider = StubProvider.new([
                                  transient_error,
                                  StubProvider.tool_call(id: "c1", name: "noop", arguments: {}),
                                  transient_error,
                                  StubProvider.text("Final.")
                                ])
    agent = Truffle::Agent.new(provider: provider, tools: [noop],
                               retry_settings: { enabled: true, max_retries: 1, base_delay_ms: 0 })

    result = agent.run("go")

    assert_equal "Final.", result
    assert_equal 4, provider.calls.size
  end
end
