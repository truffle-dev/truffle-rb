# frozen_string_literal: true

require "test_helper"

class TestAgentLoop < Minitest::Test
  def setup
    @add = Truffle::Tool.define("add", "Add two integers") do
      param :a, :integer, required: true
      param :b, :integer, required: true
      run { |a:, b:| a + b }
    end
  end

  # The model asks for a tool, gets the result, then answers in plain text.
  def test_runs_tool_then_returns_final_text
    provider = StubProvider.new([
                                  StubProvider.tool_call(id: "call_1", name: "add",
                                                         arguments: { "a" => 2, "b" => 3 }),
                                  StubProvider.text("The answer is 5.")
                                ])
    agent = Truffle::Agent.new(provider: provider, system_prompt: "calc", tools: [@add])

    result = agent.run("What is 2 + 3?")

    assert_equal "The answer is 5.", result
    # Two chat calls: one that requested the tool, one that answered.
    assert_equal 2, provider.calls.length
  end

  def test_history_contains_tool_result_linked_by_id
    provider = StubProvider.new([
                                  StubProvider.tool_call(id: "call_9", name: "add",
                                                         arguments: { "a" => 4, "b" => 6 }),
                                  StubProvider.text("10")
                                ])
    agent = Truffle::Agent.new(provider: provider, tools: [@add])
    agent.run("4 + 6?")

    tool_msg = agent.messages.find { |m| m.role == :tool }

    refute_nil tool_msg
    assert_equal "call_9", tool_msg.tool_call_id
    assert_equal "10", tool_msg.text
  end

  # A tool that returns structured data reaches the model as JSON in the
  # tool-result message: the agent passes the serialized return through
  # untouched, so the value the model reads is valid JSON, not Ruby inspect.
  def test_structured_tool_return_reaches_history_as_json
    record = Truffle::Tool.define("record", "Return a record") do
      run { { city: "Berlin", capital: true } }
    end
    provider = StubProvider.new([
                                  StubProvider.tool_call(id: "c1", name: "record", arguments: {}),
                                  StubProvider.text("done")
                                ])
    agent = Truffle::Agent.new(provider: provider, tools: [record])
    agent.run("look it up")

    tool_msg = agent.messages.find { |m| m.role == :tool }

    assert_equal '{"city":"Berlin","capital":true}', tool_msg.text
  end

  def test_run_accepts_images_on_the_user_turn
    provider = StubProvider.new([StubProvider.text("seen")])
    agent = Truffle::Agent.new(provider: provider)
    image = Truffle::Content::Image.new(data: "base64data", mime_type: "image/png")

    agent.run("look", images: [image])

    user = provider.calls.first[:messages].find { |message| message[:role] == :user }

    assert_equal [
      { type: :text, text: "look" },
      { type: :image, data: "base64data", mime_type: "image/png" }
    ], user[:content]
  end

  def test_emits_events_in_order
    provider = StubProvider.new([
                                  StubProvider.tool_call(id: "c1", name: "add",
                                                         arguments: { "a" => 1, "b" => 1 }),
                                  StubProvider.text("2")
                                ])
    agent = Truffle::Agent.new(provider: provider, tools: [@add])

    seen = []
    agent.on { |type, _payload| seen << type }
    agent.run("1 + 1?")

    assert_equal :agent_start, seen.first
    assert_equal :agent_end, seen.last
    assert_includes seen, :tool_call
    assert_includes seen, :tool_result
    # tool_call must come before its tool_result
    assert_operator seen.index(:tool_call), :<, seen.index(:tool_result)
  end

  def test_scoped_event_listener_receives_payload
    provider = StubProvider.new([
                                  StubProvider.tool_call(id: "c1", name: "add",
                                                         arguments: { "a" => 7, "b" => 8 }),
                                  StubProvider.text("15")
                                ])
    agent = Truffle::Agent.new(provider: provider, tools: [@add])

    captured = nil
    agent.on(:tool_result) { |payload| captured = payload }
    agent.run("7 + 8?")

    assert_equal "add", captured[:call].name
    assert_equal "15", captured[:result]
  end

  def test_unknown_tool_is_reported_not_raised
    provider = StubProvider.new([
                                  StubProvider.tool_call(id: "c1", name: "nope", arguments: {}),
                                  StubProvider.text("sorry")
                                ])
    agent = Truffle::Agent.new(provider: provider, tools: [@add])
    agent.run("do the thing")

    tool_msg = agent.messages.find { |m| m.role == :tool }

    assert_includes tool_msg.text, "unknown tool 'nope'"
  end

  def test_tool_exception_is_caught_and_fed_back
    boom = Truffle::Tool.define("boom", "always raises") do
      run { raise "kaboom" }
    end
    provider = StubProvider.new([
                                  StubProvider.tool_call(id: "c1", name: "boom", arguments: {}),
                                  StubProvider.text("handled")
                                ])
    agent = Truffle::Agent.new(provider: provider, tools: [boom])
    result = agent.run("go")

    tool_msg = agent.messages.find { |m| m.role == :tool }

    assert_includes tool_msg.text, "kaboom"
    assert_equal "handled", result
  end

  def test_max_turns_guard_ends_with_error_stop_reason
    # Provider always asks for a tool, never settles -> must hit the guard.
    infinite = Class.new(Truffle::Providers::Base) do
      attr_reader :calls

      def initialize
        super
        @calls = 0
      end

      def chat(messages:, tools: [], model: nil, **_)
        @calls += 1
        StubProvider.tool_call(id: "x", name: "add", arguments: { "a" => 1, "b" => 1 })
      end
    end.new
    agent = Truffle::Agent.new(provider: infinite, tools: [@add], max_turns: 3)

    ended = nil
    agent.on(:agent_end) { |payload| ended = payload }

    result = agent.run("loop forever")

    assert_nil result
    assert_equal 3, infinite.calls
    assert_equal Truffle::StopReason::ERROR, ended[:stop_reason]
    assert_includes ended[:error_message], "max_turns"
  end

  def test_agent_end_surfaces_stop_reason
    provider = StubProvider.new([
                                  StubProvider.tool_call(id: "c1", name: "add",
                                                         arguments: { "a" => 1, "b" => 1 }),
                                  StubProvider.text("2")
                                ])
    agent = Truffle::Agent.new(provider: provider, tools: [@add])

    ended = nil
    agent.on(:agent_end) { |payload| ended = payload }
    agent.run("1 + 1?")

    # The terminating turn answered without a tool, so its reason is the run's.
    assert_equal :stop, ended[:stop_reason]
    assert_nil ended[:error_message]
  end

  def test_agent_end_reports_length_when_the_model_is_truncated
    provider = StubProvider.new([StubProvider.text("cut o", finish_reason: "length")])
    agent = Truffle::Agent.new(provider: provider)

    ended = nil
    agent.on(:agent_end) { |payload| ended = payload }
    agent.run("write a long essay")

    assert_equal :length, ended[:stop_reason]
  end

  def test_reset_clears_history_but_keeps_system_prompt
    provider = StubProvider.new([StubProvider.text("hi")])
    agent = Truffle::Agent.new(provider: provider, system_prompt: "be nice")
    agent.run("hello")

    assert_operator agent.messages.length, :>, 1

    agent.reset

    assert_equal 1, agent.messages.length
    assert_equal :system, agent.messages.first.role
  end
end
