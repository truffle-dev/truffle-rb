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
end
