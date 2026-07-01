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

  def write_session_file(name, records)
    path = File.join(@dir, name)
    body = records.map { |record| JSON.generate(record) }.join("\n")
    File.write(path, "#{body}\n")
    path
  end

  def load_session(session)
    session.flush
    Truffle::Session.load(session.file)
  end

  def test_create_defers_writing_until_the_first_assistant_message
    session = Truffle::Session.create(dir: @dir, cwd: "/work")

    refute_path_exists session.file

    session.append_message(Truffle::Message.user("hello"))

    refute_path_exists session.file

    session.append_message(Truffle::Message.assistant(content: "hi"))
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

  def test_create_accepts_an_explicit_session_id
    session = Truffle::Session.create(dir: @dir, cwd: "/work", id: "project.1-alpha")

    assert_equal "project.1-alpha", session.id
    assert_match(/_project\.1-alpha\.jsonl\z/, File.basename(session.file))
  end

  def test_create_rejects_an_invalid_session_id
    error = assert_raises(ArgumentError) do
      Truffle::Session.create(dir: @dir, cwd: "/work", id: "../bad")
    end

    assert_includes error.message, "Session id must be non-empty"
  end

  def test_create_without_a_dir_lands_in_the_default_per_project_directory
    agent_dir = File.join(@dir, "agent")
    with_env("TRUFFLE_AGENT_DIR" => agent_dir) do
      session = Truffle::Session.create(cwd: "/home/ada/proj")

      expected_dir = Truffle::Config.default_session_dir(cwd: "/home/ada/proj",
                                                         agent_dir: agent_dir)

      assert_equal expected_dir, File.dirname(session.file)
      assert_equal File.join(agent_dir, "sessions", "--home-ada-proj--"), expected_dir
    end
  end

  def with_env(overrides)
    previous = overrides.transform_values { |_| :__absent__ }
    overrides.each_key { |key| previous[key] = ENV.fetch(key, :__absent__) }
    overrides.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each do |key, value|
      value == :__absent__ ? ENV.delete(key) : ENV[key] = value
    end
  end

  def test_create_records_an_optional_parent_session
    session = Truffle::Session.create(dir: @dir, cwd: "/work", parent_session: "abc123")
    session.flush
    header = JSON.parse(File.read(session.file).each_line.first)

    assert_equal "abc123", header["parent_session"]
    assert_equal "abc123", session.parent_session
  end

  def test_fork_from_copies_entries_into_a_new_parented_session
    source = Truffle::Session.create(dir: @dir, cwd: "/source", tools: %w[read bash])
    source.append_model_change(provider: "openai", model_id: "gpt-4o-mini")
    source.append_message(Truffle::Message.user("hello"))
    source.append_message(Truffle::Message.assistant(content: "hi"))
    source.flush

    fork_dir = File.join(@dir, "forks")
    forked = Truffle::Session.fork_from(
      source.file,
      cwd: "/target",
      dir: fork_dir,
      id: "fork-1"
    )

    assert_equal "fork-1", forked.id
    assert_equal "/target", forked.cwd
    assert_equal source.file, forked.parent_session
    assert_equal %w[read bash], forked.tools
    assert_equal %w[hello hi], forked.messages.map(&:text)
    assert_equal "gpt-4o-mini", forked.context.model.model_id
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

    refute_path_exists session.file

    session.append_message(Truffle::Message.assistant(content: "second"))
    lines = File.read(session.file).each_line.to_a

    assert_equal 3, lines.length
  end

  def test_messages_round_trips_a_loaded_conversation
    session = Truffle::Session.create(dir: @dir, cwd: "/work")
    session.append_message(Truffle::Message.user("hello"))
    session.append_message(Truffle::Message.assistant(content: "hi there"))

    reloaded = load_session(session)
    messages = reloaded.messages

    assert_equal %i[user assistant], messages.map(&:role)
    assert_equal "hello", messages[0].text
    assert_equal "hi there", messages[1].text
  end

  def test_messages_preserves_chronological_order
    session = Truffle::Session.create(dir: @dir, cwd: "/work")
    5.times { |i| session.append_message(Truffle::Message.user("m#{i}")) }

    reloaded = load_session(session)

    assert_equal %w[m0 m1 m2 m3 m4], reloaded.messages.map(&:text)
  end

  def test_round_trips_a_tool_call_and_tool_result
    session = Truffle::Session.create(dir: @dir, cwd: "/work")
    call = Truffle::ToolCall.new(id: "c1", name: "add", arguments: { "a" => 1, "b" => 2 })
    session.append_message(Truffle::Message.assistant(tool_calls: [call]))
    session.append_message(Truffle::Message.tool(content: "3", tool_call_id: "c1", name: "add"))

    messages = load_session(session).messages
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
    session.flush
    File.open(session.file, "a") { |handle| handle.write('{"type":"message",') }

    reloaded = Truffle::Session.load(session.file)

    assert_equal ["kept"], reloaded.messages.map(&:text)
  end

  def test_load_rejects_a_malformed_middle_line
    path = write_session_file(
      "corrupt-middle.jsonl",
      [
        { type: "session", version: Truffle::Session::SESSION_VERSION,
          id: "sess-corrupt", timestamp: "2025-01-01T00:00:00Z", cwd: "/work" },
        { type: "message", id: "11111111", parent_id: nil,
          timestamp: "2025-01-01T00:00:01Z",
          message: { role: "user", content: [{ type: "text", text: "kept" }] } }
      ]
    )
    File.open(path, "a") { |handle| handle.write("{not json}\n") }
    File.open(path, "a") do |handle|
      handle.write(JSON.generate(
                     type: "message", id: "22222222", parent_id: "11111111",
                     timestamp: "2025-01-01T00:00:02Z",
                     message: { role: "assistant", content: [{ type: "text", text: "hidden" }] }
                   ))
      handle.write("\n")
    end

    error = assert_raises(ArgumentError) { Truffle::Session.load(path) }

    assert_match(/malformed session line 3/, error.message)
  end

  def test_append_after_load_does_not_reparse_unknown_content_blocks
    path = write_session_file(
      "future-content.jsonl",
      [
        { type: "session", version: Truffle::Session::SESSION_VERSION,
          id: "sess-future", timestamp: "2025-01-01T00:00:00Z", cwd: "/work" },
        { type: "message", id: "11111111", parent_id: nil,
          timestamp: "2025-01-01T00:00:01Z",
          message: { role: "user", content: [{ type: "future", value: "kept raw" }] } }
      ]
    )

    session = Truffle::Session.load(path)

    appended = session.append_message(Truffle::Message.user("new turn"))
    lines = File.read(path).each_line.map { |line| JSON.parse(line) }

    assert_equal appended, lines.last.fetch("id")
    assert_equal "new turn", lines.last.dig("message", "content", 0, "text")
  end

  def test_two_loaded_sessions_append_to_the_latest_file_leaf
    session = Truffle::Session.create(dir: @dir, cwd: "/work")
    session.append_message(Truffle::Message.user("start"))
    session.append_message(Truffle::Message.assistant(content: "ready"))

    first = Truffle::Session.load(session.file)
    second = Truffle::Session.load(session.file)
    first_id = first.append_message(Truffle::Message.user("from first"))
    second_id = second.append_message(Truffle::Message.user("from second"))
    reloaded = Truffle::Session.load(session.file)

    assert_equal ["start", "ready", "from first", "from second"], reloaded.messages.map(&:text)
    first_entry = reloaded.entry(first_id)
    second_entry = reloaded.entry(second_id)

    assert_equal first_entry[:id], second_entry[:parent_id]
  end

  def test_load_migrates_v1_entries_to_the_current_tree_shape
    path = write_session_file(
      "v1.jsonl",
      [
        { type: "session", id: "sess-1", timestamp: "2025-01-01T00:00:00Z", cwd: "/work" },
        { type: "message", timestamp: "2025-01-01T00:00:01Z",
          message: { role: "user", content: "hello" } },
        { type: "message", timestamp: "2025-01-01T00:00:02Z",
          message: { role: "assistant", content: [{ type: "text", text: "hi" }] } }
      ]
    )

    session = Truffle::Session.load(path)
    entries = session.entries
    rewritten = File.read(path).each_line.map { |line| JSON.parse(line) }

    assert_equal Truffle::Session::SESSION_VERSION, session.version
    assert_equal %w[hello hi], session.messages.map(&:text)
    assert_match(/\A\h{8}\z/, entries[0][:id])
    assert_nil entries[0][:parent_id]
    assert_equal entries[0][:id], entries[1][:parent_id]
    assert_equal Truffle::Session::SESSION_VERSION, rewritten.first["version"]
    assert rewritten[2].key?("parent_id")
    refute rewritten[2].key?("parentId")
  end

  def test_load_keeps_a_backup_when_rewriting_a_legacy_session
    path = write_session_file(
      "v1-backup.jsonl",
      [
        { type: "session", id: "sess-1", timestamp: "2025-01-01T00:00:00Z", cwd: "/work" },
        { type: "message", timestamp: "2025-01-01T00:00:01Z",
          message: { role: "user", content: "hello" } }
      ]
    )
    original = File.read(path)

    Truffle::Session.load(path)

    assert_equal original, File.read("#{path}.bak")
    refute_equal original, File.read(path)
    assert_empty Dir.glob(File.join(@dir, ".v1-backup.jsonl.*.tmp"))
  end

  def test_load_migrates_v1_compaction_kept_index_to_kept_id
    path = write_session_file(
      "v1-compaction.jsonl",
      [
        { type: "session", id: "sess-1", timestamp: "2025-01-01T00:00:00Z", cwd: "/work" },
        { type: "message", timestamp: "2025-01-01T00:00:01Z",
          message: { role: "user", content: "old" } },
        { type: "message", timestamp: "2025-01-01T00:00:02Z",
          message: { role: "user", content: "kept" } },
        { type: "compaction", timestamp: "2025-01-01T00:00:03Z",
          summary: "summary", first_kept_entry_index: 2, tokens_before: 12 }
      ]
    )

    session = Truffle::Session.load(path)
    compaction = session.entries.last
    texts = session.context.messages.map(&:text)

    assert_equal session.entries[1][:id], compaction[:first_kept_entry_id]
    refute compaction.key?(:first_kept_entry_index)
    assert_includes texts.first, "summary"
    assert_equal "kept", texts.last
  end

  def test_load_migrates_v2_camel_case_fields_to_current_names
    path = write_session_file(
      "v2.jsonl",
      [
        { type: "session", version: 2, id: "sess-2", timestamp: "2025-01-01T00:00:00Z",
          cwd: "/work", parentSession: "parent" },
        { type: "message", id: "11111111", parentId: nil, timestamp: "2025-01-01T00:00:01Z",
          message: { role: "user", content: "hello" } },
        { type: "model_change", id: "22222222", parentId: "11111111",
          timestamp: "2025-01-01T00:00:02Z", provider: "openai", modelId: "gpt-4o-mini" }
      ]
    )

    session = Truffle::Session.load(path)
    rewritten = File.read(path)

    assert_equal "parent", session.parent_session
    assert_equal "11111111", session.entries[1][:parent_id]
    assert_equal "gpt-4o-mini", session.context.model.model_id
    refute_includes rewritten, "parentId"
    refute_includes rewritten, "modelId"
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

    context = load_session(session).context

    assert_equal "high", context.thinking_level
    assert_equal "anthropic", context.model.provider
    assert_equal "claude-opus-4-8", context.model.model_id
  end

  def test_context_messages_skip_settings_entries
    session = Truffle::Session.create(dir: @dir, cwd: "/work")
    session.append_message(Truffle::Message.user("one"))
    session.append_model_change(provider: "openai", model_id: "gpt-4o")
    session.append_message(Truffle::Message.assistant(content: "two"))

    context = load_session(session).context

    assert_equal %w[one two], context.messages.map(&:text)
  end

  def test_append_session_info_sets_a_normalized_display_name
    session = Truffle::Session.create(dir: @dir, cwd: "/work")

    entry_id = session.append_session_info("  hello\nworld\r\nagain  ")

    assert_equal entry_id, session.leaf_id
    assert_equal "hello world again", session.session_name
    assert_equal "session_info", session.entry(entry_id)[:type]
    assert_equal "hello world again", session.entry(entry_id)[:name]
    assert_empty session.context.messages
  end

  def test_session_name_survives_reload_and_empty_name_clears_it
    session = Truffle::Session.create(dir: @dir, cwd: "/work")
    session.append_session_info("kept")

    assert_equal "kept", load_session(session).session_name

    session.append_session_info("   ")

    assert_nil load_session(session).session_name
  end

  def test_context_after_compaction_returns_summary_then_kept_tail
    session = Truffle::Session.create(dir: @dir, cwd: "/work")
    session.append_message(Truffle::Message.user("old one"))
    session.append_message(Truffle::Message.user("old two"))
    kept = session.append_message(Truffle::Message.user("kept"))
    session.append_compaction(summary: "they said old things", first_kept_entry_id: kept,
                              tokens_before: 1234)
    session.append_message(Truffle::Message.assistant(content: "after"))

    context = load_session(session).context
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

    texts = load_session(session).context.messages.map(&:text)

    refute_includes texts, "dropped"
    assert_includes texts, "kept"
  end

  def test_raw_messages_still_include_pre_compaction_history
    session = Truffle::Session.create(dir: @dir, cwd: "/work")
    session.append_message(Truffle::Message.user("dropped from context"))
    kept = session.append_message(Truffle::Message.user("kept"))
    session.append_compaction(summary: "summary", first_kept_entry_id: kept, tokens_before: 10)

    raw = load_session(session).messages.map(&:text)

    assert_equal ["dropped from context", "kept"], raw
  end

  def test_settings_and_compaction_entries_round_trip_through_the_file
    session = Truffle::Session.create(dir: @dir, cwd: "/work")
    session.append_thinking_level_change("medium")
    session.append_compaction(summary: "s", first_kept_entry_id: "none", tokens_before: 5)
    types = load_session(session).entries.map { |entry| entry[:type] }

    assert_equal %w[thinking_level_change compaction], types
  end
end
