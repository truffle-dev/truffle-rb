# frozen_string_literal: true

require "test_helper"

# The assembly half of compaction: prepare_compaction works out the cut, the
# history to summarize, the split-turn prefix, and the file operations from a
# session path (pure, offline), and compact turns a prepared cut into a finished
# summary by calling the model (provider stubbed, so it stays offline).
class TestCompactionPrepare < Minitest::Test
  Compaction = Truffle::Compaction

  # ---- fixtures ----

  # A message entry of `chars` characters, so its token estimate is ceil(chars/4).
  def message_entry(id, role, chars)
    { type: "message", id: id, message: Truffle::Message.new(role: role, content: "x" * chars).to_h }
  end

  # A message entry without an id, to exercise the invalid-session guard.
  def message_entry_without_id(role, chars)
    { type: "message", message: Truffle::Message.new(role: role, content: "x" * chars).to_h }
  end

  def compaction_entry(id, first_kept_entry_id, summary: "## old", details: nil)
    entry = { type: "compaction", id: id, summary: summary,
              first_kept_entry_id: first_kept_entry_id }
    entry[:details] = details if details
    entry
  end

  def settings(keep:, reserve: 100)
    Compaction::Settings.new(enabled: true, reserve_tokens: reserve, keep_recent_tokens: keep)
  end

  def six_turn_path
    [
      message_entry("0", :user, 40),
      message_entry("1", :assistant, 40),
      message_entry("2", :user, 40),
      message_entry("3", :assistant, 40),
      message_entry("4", :user, 40),
      message_entry("5", :assistant, 40)
    ]
  end

  def file_ops(read: [], written: [], edited: [])
    Compaction::FileOperations.new(
      read: Set.new(read), written: Set.new(written), edited: Set.new(edited)
    )
  end

  def summary_model(max_output: 0)
    Truffle::Model.new(
      id: "test-model", name: "Test", provider: :openai, api: :chat_completions,
      context_window: 128_000, max_output: max_output,
      cost: { input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0 }
    )
  end

  def error_response(message)
    Truffle::Response.new(
      message: Truffle::Message.assistant(content: "ignored"),
      stop_reason: Truffle::StopReason::ERROR, error_message: message
    )
  end

  def preparation(**overrides)
    defaults = {
      first_kept_entry_id: "k", messages_to_summarize: [Truffle::Message.user("history")],
      turn_prefix_messages: [], split_turn: false, tokens_before: 1234,
      previous_summary: nil, file_ops: file_ops, settings: Compaction::DEFAULT_SETTINGS
    }
    Compaction::Preparation.new(**defaults, **overrides)
  end

  # ---- prepare_compaction ----

  def test_prepare_returns_nil_for_an_empty_path
    assert_nil Compaction.prepare_compaction([], settings(keep: 10))
  end

  def test_prepare_returns_nil_when_the_last_entry_is_already_a_compaction
    entries = [message_entry("0", :user, 40), compaction_entry("c", "0")]

    assert_nil Compaction.prepare_compaction(entries, settings(keep: 10))
  end

  def test_prepare_builds_a_clean_cut_with_no_prior_compaction
    prep = Compaction.prepare_compaction(six_turn_path, settings(keep: 15))

    # keep 15: cut snaps to the user message at index 4, a clean boundary.
    assert_equal "4", prep.first_kept_entry_id
    refute prep.split_turn
    assert_empty prep.turn_prefix_messages
    # boundary_start 0 up to history_end 4: entries 0..3.
    assert_equal 4, prep.messages_to_summarize.length
    assert_nil prep.previous_summary
    # the whole six-message path estimates 6 * ceil(40/4) = 60 tokens.
    assert_equal 60, prep.tokens_before
  end

  def test_prepare_records_a_split_turn_prefix_when_the_cut_lands_inside_a_turn
    prep = Compaction.prepare_compaction(six_turn_path, settings(keep: 25))

    # keep 25: cut lands on the assistant at index 3, turn start is the user at 2.
    assert_equal "3", prep.first_kept_entry_id
    assert prep.split_turn
    # history is entries 0..1; the prefix is the lone user entry at index 2.
    assert_equal 2, prep.messages_to_summarize.length
    assert_equal 1, prep.turn_prefix_messages.length
  end

  def test_prepare_continues_from_a_prior_compaction
    entries = [
      message_entry("0", :user, 40),
      message_entry("1", :assistant, 40),
      compaction_entry("c", "1", summary: "## prior",
                                 details: { read_files: ["a.rb"], modified_files: ["b.rb"] }),
      message_entry("3", :user, 40),
      message_entry("4", :assistant, 40)
    ]

    prep = Compaction.prepare_compaction(entries, settings(keep: 15))

    # The prior summary is carried forward and the window starts at its kept entry.
    assert_equal "## prior", prep.previous_summary
    # keep 15: cut snaps to the user at index 3; history is the window 1..2 (the
    # assistant at 1; the compaction at 2 contributes no message).
    assert_equal "3", prep.first_kept_entry_id
    assert_equal 1, prep.messages_to_summarize.length

    # The prior compaction's file lists seed the new file operations.
    lists = Compaction.compute_file_lists(prep.file_ops)

    assert_equal ["a.rb"], lists[:read_files]
    assert_equal ["b.rb"], lists[:modified_files]
  end

  def test_prepare_extracts_file_ops_from_the_summarized_history
    read_call = Truffle::ToolCall.new(id: "1", name: "read", arguments: { "path" => "lib/x.rb" })
    write_call = Truffle::ToolCall.new(id: "2", name: "write", arguments: { "path" => "lib/y.rb" })
    entries = [
      { type: "message", id: "0",
        message: Truffle::Message.assistant(tool_calls: [read_call, write_call]).to_h },
      message_entry("1", :user, 40),
      message_entry("2", :assistant, 80_000) # large, forces the cut to keep only the tail
    ]

    prep = Compaction.prepare_compaction(entries, settings(keep: 5))
    lists = Compaction.compute_file_lists(prep.file_ops)

    assert_equal ["lib/x.rb"], lists[:read_files]
    assert_equal ["lib/y.rb"], lists[:modified_files]
  end

  def test_prepare_raises_invalid_session_when_the_first_kept_entry_has_no_id
    entries = [message_entry("0", :user, 40), message_entry_without_id(:assistant, 40)]

    error = assert_raises(Compaction::Error) do
      Compaction.prepare_compaction(entries, settings(keep: 5))
    end

    assert_equal :invalid_session, error.kind
  end

  # ---- compact ----

  def test_compact_summarizes_the_history_and_appends_file_tags
    prep = preparation(file_ops: file_ops(read: ["a.rb"], edited: ["b.rb"]))
    provider = StubProvider.new([StubProvider.text("## Goal\nship it")])

    result = Compaction.compact(prep, provider, summary_model)

    assert_equal "k", result.first_kept_entry_id
    assert_equal 1234, result.tokens_before
    assert_includes result.summary, "## Goal\nship it"
    assert_includes result.summary, "<read-files>\na.rb\n</read-files>"
    assert_includes result.summary, "<modified-files>\nb.rb\n</modified-files>"
    assert_equal ["a.rb"], result.details[:read_files]
    assert_equal ["b.rb"], result.details[:modified_files]
    assert_equal 1, provider.calls.length
  end

  def test_compact_joins_a_split_turn_summary_under_the_divider
    prep = preparation(
      split_turn: true, messages_to_summarize: [Truffle::Message.user("history")],
      turn_prefix_messages: [Truffle::Message.user("turn start")]
    )
    provider = StubProvider.new([StubProvider.text("HISTORY"), StubProvider.text("PREFIX")])

    result = Compaction.compact(prep, provider, summary_model)

    assert_equal "HISTORY\n\n---\n\n**Turn Context (split turn):**\n\nPREFIX", result.summary
    assert_equal 2, provider.calls.length
  end

  def test_compact_uses_no_prior_history_when_a_split_turn_has_no_history
    prep = preparation(
      split_turn: true, messages_to_summarize: [],
      turn_prefix_messages: [Truffle::Message.user("turn start")]
    )
    provider = StubProvider.new([StubProvider.text("PREFIX")])

    result = Compaction.compact(prep, provider, summary_model)

    assert_equal "No prior history.\n\n---\n\n**Turn Context (split turn):**\n\nPREFIX",
                 result.summary
    # only the prefix is summarized; the empty history makes no provider call.
    assert_equal 1, provider.calls.length
  end

  def test_compact_treats_a_split_turn_with_no_prefix_as_a_plain_summary
    prep = preparation(split_turn: true, turn_prefix_messages: [])
    provider = StubProvider.new([StubProvider.text("SUMMARY")])

    result = Compaction.compact(prep, provider, summary_model)

    refute_includes result.summary, "Turn Context"
    assert_equal 1, provider.calls.length
  end

  def test_compact_propagates_a_summarizer_error
    prep = preparation
    provider = StubProvider.new([error_response("rate limited")])

    error = assert_raises(Compaction::Error) { Compaction.compact(prep, provider, summary_model) }

    assert_equal :summarization_failed, error.kind
  end

  def test_compact_raises_invalid_session_on_a_missing_first_kept_id
    prep = preparation(first_kept_entry_id: "")
    provider = StubProvider.new([StubProvider.text("ignored")])

    error = assert_raises(Compaction::Error) { Compaction.compact(prep, provider, summary_model) }

    assert_equal :invalid_session, error.kind
  end
end
