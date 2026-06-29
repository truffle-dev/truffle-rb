# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "json"

# The append-only JSONL session store, a port of pi's session manager. A session
# is a header line followed by message entries chained through parent_id; the
# current conversation is the leaf-to-root path. These exercise the contract a
# resumed agent depends on: a header is written, messages append in order, a file
# reloads into the same Message list, and a malformed file is rejected. Files
# live in a temp dir so the suite stays hermetic.
class TestSession < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("truffle-session")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_create_writes_a_header_line
    session = Truffle::Session.create(dir: @dir, cwd: "/work")
    header = JSON.parse(File.read(session.file).each_line.first)

    assert_equal "session", header["type"]
    assert_equal Truffle::Session::SESSION_VERSION, header["version"]
    assert_equal "/work", header["cwd"]
    assert_equal session.id, header["id"]
  end

  def test_create_file_name_is_path_safe
    session = Truffle::Session.create(dir: @dir, cwd: "/work")
    name = File.basename(session.file)

    assert_match(/\A[\w-]+_#{Regexp.escape(session.id)}\.jsonl\z/, name)
    refute_includes name, ":"
  end

  def test_create_records_an_optional_parent_session
    session = Truffle::Session.create(dir: @dir, cwd: "/work", parent_session: "abc123")
    header = JSON.parse(File.read(session.file).each_line.first)

    assert_equal "abc123", header["parent_session"]
    assert_equal "abc123", session.parent_session
  end

  def test_append_message_returns_an_entry_id_and_advances_the_leaf
    session = Truffle::Session.create(dir: @dir, cwd: "/work")
    id = session.append_message(Truffle::Message.user("hello"))

    assert_equal id, session.leaf_id
    assert_match(/\A\h{8}\z/, id)
  end

  def test_append_message_persists_one_line_per_message
    session = Truffle::Session.create(dir: @dir, cwd: "/work")
    session.append_message(Truffle::Message.user("first"))
    session.append_message(Truffle::Message.assistant(content: "second"))
    lines = File.read(session.file).each_line.to_a

    assert_equal 3, lines.length
  end

  def test_messages_round_trips_a_loaded_conversation
    session = Truffle::Session.create(dir: @dir, cwd: "/work")
    session.append_message(Truffle::Message.user("hello"))
    session.append_message(Truffle::Message.assistant(content: "hi there"))

    reloaded = Truffle::Session.load(session.file)
    messages = reloaded.messages

    assert_equal %i[user assistant], messages.map(&:role)
    assert_equal "hello", messages[0].text
    assert_equal "hi there", messages[1].text
  end

  def test_messages_preserves_chronological_order
    session = Truffle::Session.create(dir: @dir, cwd: "/work")
    5.times { |i| session.append_message(Truffle::Message.user("m#{i}")) }

    reloaded = Truffle::Session.load(session.file)

    assert_equal %w[m0 m1 m2 m3 m4], reloaded.messages.map(&:text)
  end

  def test_round_trips_a_tool_call_and_tool_result
    session = Truffle::Session.create(dir: @dir, cwd: "/work")
    call = Truffle::ToolCall.new(id: "c1", name: "add", arguments: { "a" => 1, "b" => 2 })
    session.append_message(Truffle::Message.assistant(tool_calls: [call]))
    session.append_message(Truffle::Message.tool(content: "3", tool_call_id: "c1", name: "add"))

    messages = Truffle::Session.load(session.file).messages
    restored_call = messages[0].tool_calls.first

    assert_equal "add", restored_call.name
    assert_equal({ "a" => 1, "b" => 2 }, restored_call.arguments)
    assert_equal "c1", messages[1].tool_call_id
    assert_equal "3", messages[1].text
  end

  def test_load_rejects_a_file_without_a_session_header
    bogus = File.join(@dir, "bogus.jsonl")
    File.write(bogus, "#{JSON.generate({ type: "message", id: "x" })}\n")

    assert_raises(ArgumentError) { Truffle::Session.load(bogus) }
  end

  def test_load_tolerates_a_truncated_final_line
    session = Truffle::Session.create(dir: @dir, cwd: "/work")
    session.append_message(Truffle::Message.user("kept"))
    File.open(session.file, "a") { |handle| handle.write('{"type":"message",') }

    reloaded = Truffle::Session.load(session.file)

    assert_equal ["kept"], reloaded.messages.map(&:text)
  end

  def test_messages_is_empty_for_a_fresh_session
    session = Truffle::Session.create(dir: @dir, cwd: "/work")

    assert_empty session.messages
  end

  def test_context_defaults_to_off_thinking_and_no_model
    session = Truffle::Session.create(dir: @dir, cwd: "/work")
    context = session.context

    assert_equal "off", context.thinking_level
    assert_nil context.model
    assert_empty context.messages
  end

  def test_context_recovers_the_latest_model_and_thinking_level
    session = Truffle::Session.create(dir: @dir, cwd: "/work")
    session.append_model_change(provider: "openai", model_id: "gpt-4o")
    session.append_thinking_level_change("low")
    session.append_message(Truffle::Message.user("hi"))
    session.append_model_change(provider: "anthropic", model_id: "claude-opus-4-8")
    session.append_thinking_level_change("high")

    context = Truffle::Session.load(session.file).context

    assert_equal "high", context.thinking_level
    assert_equal "anthropic", context.model.provider
    assert_equal "claude-opus-4-8", context.model.model_id
  end

  def test_context_messages_skip_settings_entries
    session = Truffle::Session.create(dir: @dir, cwd: "/work")
    session.append_message(Truffle::Message.user("one"))
    session.append_model_change(provider: "openai", model_id: "gpt-4o")
    session.append_message(Truffle::Message.assistant(content: "two"))

    context = Truffle::Session.load(session.file).context

    assert_equal %w[one two], context.messages.map(&:text)
  end

  def test_context_after_compaction_returns_summary_then_kept_tail
    session = Truffle::Session.create(dir: @dir, cwd: "/work")
    session.append_message(Truffle::Message.user("old one"))
    session.append_message(Truffle::Message.user("old two"))
    kept = session.append_message(Truffle::Message.user("kept"))
    session.append_compaction(summary: "they said old things", first_kept_entry_id: kept,
                              tokens_before: 1234)
    session.append_message(Truffle::Message.assistant(content: "after"))

    context = Truffle::Session.load(session.file).context
    texts = context.messages.map(&:text)

    assert_equal :user, context.messages.first.role
    assert_includes texts.first, "they said old things"
    assert_includes texts.first, "<summary>"
    assert_equal %w[kept after], texts.drop(1)
  end

  def test_context_compaction_drops_turns_before_the_kept_id
    session = Truffle::Session.create(dir: @dir, cwd: "/work")
    session.append_message(Truffle::Message.user("dropped"))
    kept = session.append_message(Truffle::Message.user("kept"))
    session.append_compaction(summary: "summary", first_kept_entry_id: kept, tokens_before: 10)

    texts = Truffle::Session.load(session.file).context.messages.map(&:text)

    refute_includes texts, "dropped"
    assert_includes texts, "kept"
  end

  def test_raw_messages_still_include_pre_compaction_history
    session = Truffle::Session.create(dir: @dir, cwd: "/work")
    session.append_message(Truffle::Message.user("dropped from context"))
    kept = session.append_message(Truffle::Message.user("kept"))
    session.append_compaction(summary: "summary", first_kept_entry_id: kept, tokens_before: 10)

    raw = Truffle::Session.load(session.file).messages.map(&:text)

    assert_equal ["dropped from context", "kept"], raw
  end

  def test_settings_and_compaction_entries_round_trip_through_the_file
    session = Truffle::Session.create(dir: @dir, cwd: "/work")
    session.append_thinking_level_change("medium")
    session.append_compaction(summary: "s", first_kept_entry_id: "none", tokens_before: 5)
    types = Truffle::Session.load(session.file).entries.map { |entry| entry[:type] }

    assert_equal %w[thinking_level_change compaction], types
  end
end
