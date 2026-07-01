# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# The agent loop auto-compacts a session-backed run: at the top of a turn, if
# the previous response's reported context crossed the model's threshold, the
# older turns are summarized into a session compaction entry and the running
# context is rebuilt from it before the provider is called again.
class TestAgentCompaction < Minitest::Test
  # A 200_000-token window, so the threshold is 200_000 - 16_384 = 183_616.
  MODEL = "claude-opus-4-5"

  def setup
    @noop = Truffle::Tool.define("noop", "A tool that does nothing") do
      run { "done" }
    end
  end

  # Usages whose context tokens sit just over and just under the threshold.
  def over_threshold
    Truffle::Usage.new(input: 190_000)
  end

  def under_threshold
    Truffle::Usage.new(input: 1_000)
  end

  def session(dir)
    Truffle::Session.create(dir: dir, cwd: dir)
  end

  def test_compacts_when_the_previous_turn_crossed_the_threshold
    Dir.mktmpdir("truffle-compact") do |dir|
      provider = CompactingStub.new(
        [StubProvider.tool_call(id: "c1", name: "noop", arguments: {}, usage: over_threshold),
         StubProvider.text("All done.")]
      )
      agent = Truffle::Agent.new(provider: provider, model: MODEL, tools: [@noop],
                                 session: session(dir))
      events = []
      agent.on(:compaction) { |payload| events << payload }

      agent.run("start")

      # The summarizer ran once, a compaction entry was written to the session,
      # and one compaction event carried the result.
      assert_equal 1, provider.summary_calls.size
      assert(agent.session.entries.any? { |entry| entry[:type] == "compaction" })
      assert_equal 1, events.size
      refute_nil events.first[:result]

      # The rebuilt running context leads with the compaction summary message,
      # so the next turn ran under the window rather than on the full history.
      assert_equal :user, agent.messages.first.role
      assert_includes agent.messages.first.text, "compacted into the following summary"
    end
  end

  def test_does_not_compact_below_the_threshold
    Dir.mktmpdir("truffle-compact") do |dir|
      provider = CompactingStub.new(
        [StubProvider.tool_call(id: "c1", name: "noop", arguments: {}, usage: under_threshold),
         StubProvider.text("Done.")]
      )
      agent = Truffle::Agent.new(provider: provider, model: MODEL, tools: [@noop],
                                 session: session(dir))

      agent.run("start")

      # No summarizer call, no compaction entry: the session holds exactly the
      # four conversation messages the run produced, in order.
      assert_empty provider.summary_calls
      types = agent.session.entries.map { |e| e[:type] }
      messages = agent.session.entries.select { |e| e[:type] == "message" }
      roles = messages.map { |e| Truffle::Message.from_h(e[:message]).role }

      assert_equal %w[message message message message usage], types

      assert_equal %i[user assistant tool assistant], roles
    end
  end

  def test_auto_compact_false_mirrors_the_session_without_compacting
    Dir.mktmpdir("truffle-compact") do |dir|
      provider = CompactingStub.new(
        [StubProvider.tool_call(id: "c1", name: "noop", arguments: {}, usage: over_threshold),
         StubProvider.text("All done.")]
      )
      agent = Truffle::Agent.new(provider: provider, model: MODEL, tools: [@noop],
                                 session: session(dir), auto_compact: false)

      agent.run("start")

      # The threshold was crossed, but auto-compaction is off: no summary, no
      # compaction entry. The session still mirrors the conversation.
      assert_empty provider.summary_calls
      assert(agent.session.entries.none? { |entry| entry[:type] == "compaction" })
      types = agent.session.entries.map { |entry| entry[:type] }

      assert_equal %w[message message message message usage], types
    end
  end
end
