# frozen_string_literal: true

require "test_helper"

# The pairing guarantee of compaction: a tool result is never separated from the
# assistant tool call it answers. A cut may never land on a tool result, so the
# pair is either summarized together into the history or kept together in the
# tail. These tests build fixtures from real assistant(tool_call) / tool(result)
# message pairs and check the pairing survives three cut shapes: a clean cut
# between turns, a split-turn cut whose boundary falls inside a tool-call turn,
# and a continuation from a prior compaction whose kept tail holds a tool pair.
class TestCompactionToolMessages < Minitest::Test
  Compaction = Truffle::Compaction
  Message = Truffle::Message
  ToolCall = Truffle::ToolCall

  # ---- entry builders (the on-disk path shape build_context walks) ----

  def user_entry(id, chars)
    { type: "message", id: id, message: Message.user("u" * chars).to_h }
  end

  def assistant_text_entry(id, chars)
    { type: "message", id: id, message: Message.assistant(content: "x" * chars).to_h }
  end

  def tool_call_entry(id, call_id, path)
    call = ToolCall.new(id: call_id, name: "read", arguments: { "path" => path })
    { type: "message", id: id, message: Message.assistant(tool_calls: [call]).to_h }
  end

  def tool_result_entry(id, call_id, chars)
    msg = Message.tool(content: "r" * chars, tool_call_id: call_id, name: "read")
    { type: "message", id: id, message: msg.to_h }
  end

  def compaction_entry(id, first_kept_entry_id, summary:, details: nil)
    entry = { type: "compaction", id: id, summary: summary,
              first_kept_entry_id: first_kept_entry_id }
    entry[:details] = details if details
    entry
  end

  def settings(keep:, reserve: 100)
    Compaction::Settings.new(enabled: true, reserve_tokens: reserve, keep_recent_tokens: keep)
  end

  # ---- pairing assertions ----

  # Every tool message answers an assistant tool call that came before it. Walks
  # the list once, collecting tool-call ids from assistant turns, and fails on the
  # first tool result whose tool_call_id has not been announced. This is the
  # orphan check: a tool result cut loose from its call would fail here.
  def assert_tool_pairs_intact(messages)
    seen = Set.new
    messages.each do |message|
      message.tool_calls.each { |call| seen << call.id }
      next unless message.role == :tool

      assert_includes seen, message.tool_call_id,
                      "tool result #{message.tool_call_id.inspect} has no preceding tool call"
    end
  end

  # The role of the path entry with this id, for the cut-point guard: the first
  # kept entry must never be a tool result.
  def role_of(path, id)
    entry = path.find { |candidate| candidate[:id] == id }
    Message.from_h(entry[:message]).role
  end

  # The messages a preparation folds into its summary, in path order: the history
  # first, then the split-turn prefix.
  def summarized_messages(prep)
    prep.messages_to_summarize + prep.turn_prefix_messages
  end

  # The context a resumed agent rebuilds after this preparation is committed: run
  # the summarizer (stubbed), append the compaction entry the result describes,
  # and ask Session to assemble the leaf context (summary plus kept tail).
  def rebuild_after_compaction(path, prep)
    provider = StubProvider.new([StubProvider.text("## summary"), StubProvider.text("## summary")])
    result = Compaction.compact(prep, provider, summary_model)
    appended = path + [compaction_entry("cmp", result.first_kept_entry_id, summary: result.summary)]
    Truffle::Session.build_context(appended).messages
  end

  def summary_model
    Truffle::Model.new(
      id: "test-model", name: "Test", provider: :openai, api: :chat_completions,
      context_window: 128_000, max_output: 0,
      cost: { input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0 }
    )
  end

  # ---- scenario 1: clean cut between two full tool turns ----

  def clean_cut_path
    [
      user_entry("0", 40),
      tool_call_entry("1", "c1", "lib/a.rb"),
      tool_result_entry("2", "c1", 40),
      assistant_text_entry("3", 40),
      user_entry("4", 40),
      tool_call_entry("5", "c2", "lib/b.rb"),
      tool_result_entry("6", "c2", 40),
      assistant_text_entry("7", 40)
    ]
  end

  def test_clean_cut_keeps_both_tool_turns_paired
    path = clean_cut_path
    prep = Compaction.prepare_compaction(path, settings(keep: 30))

    # The cut snaps to the user that opens turn B, a clean boundary.
    assert_equal "4", prep.first_kept_entry_id
    refute prep.split_turn
    refute_equal :tool, role_of(path, prep.first_kept_entry_id)

    # Turn A (its tool pair included) is summarized; turn B stays in the tail.
    assert_tool_pairs_intact summarized_messages(prep)
    assert_tool_pairs_intact rebuild_after_compaction(path, prep)
  end

  # ---- scenario 2: split-turn cut lands inside a tool-call turn ----

  # One big tool-result turn (user, tool call, large result) followed by a small
  # assistant turn. With keep small, the recent window reaches back only to the
  # assistant text; the boundary falls inside the tool turn, so the call and its
  # result ride into the summarized prefix together and the tail is just the text.
  def split_turn_path
    [
      user_entry("0", 40),
      tool_call_entry("1", "c1", "lib/a.rb"),
      tool_result_entry("2", "c1", 200),
      assistant_text_entry("3", 40)
    ]
  end

  def test_split_turn_never_cuts_on_the_tool_result
    path = split_turn_path
    prep = Compaction.prepare_compaction(path, settings(keep: 30))

    # The cut lands on the assistant text, not the tool result one step earlier.
    assert_equal "3", prep.first_kept_entry_id
    assert prep.split_turn
    refute_equal :tool, role_of(path, prep.first_kept_entry_id)

    # The tool call and its result are both in the prefix that gets summarized,
    # and the rebuilt tail carries no orphaned tool result.
    assert_tool_pairs_intact summarized_messages(prep)
    assert_tool_pairs_intact rebuild_after_compaction(path, prep)
  end

  # ---- scenario 3: continuation from a prior compaction ----

  def continuation_path
    [
      user_entry("0", 40),
      assistant_text_entry("1", 40),
      compaction_entry("c", "1", summary: "## prior",
                                 details: { read_files: ["old.rb"], modified_files: [] }),
      user_entry("3", 40),
      tool_call_entry("4", "c1", "lib/d.rb"),
      tool_result_entry("5", "c1", 40),
      assistant_text_entry("6", 40)
    ]
  end

  def test_continuation_keeps_the_tail_tool_pair_intact
    path = continuation_path
    prep = Compaction.prepare_compaction(path, settings(keep: 30))

    # The prior summary carries forward; the cut snaps to the user at index 3,
    # so the whole new tool turn (call, result, reply) stays in the kept tail.
    assert_equal "## prior", prep.previous_summary
    assert_equal "3", prep.first_kept_entry_id
    refute prep.split_turn
    refute_equal :tool, role_of(path, prep.first_kept_entry_id)

    assert_tool_pairs_intact rebuild_after_compaction(path, prep)
  end
end
