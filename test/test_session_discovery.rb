# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "json"

# Session discovery: reading a directory of session files back to choose one to
# resume, without loading whole conversations. Port of pi's findMostRecentSession
# and readSessionHeader. Files live in a temp dir so the suite stays hermetic; a
# few tests set explicit mtimes so recency ordering is deterministic.
class TestSessionDiscovery < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("truffle-discovery")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def write_session(name, cwd: "/work", id: name, mtime: nil, extra_lines: [])
    path = File.join(@dir, "#{name}.jsonl")
    header = { type: "session", version: 1, id: id,
               timestamp: "2026-07-01T00:00:00.000Z", cwd: cwd }
    lines = [JSON.generate(header)] + extra_lines
    File.write(path, "#{lines.join("\n")}\n")
    File.utime(mtime, mtime, path) if mtime
    path
  end

  def test_read_header_returns_the_validated_header
    path = write_session("one", cwd: "/work", id: "abc")
    header = Truffle::Session.read_header(path)

    assert_equal "session", header[:type]
    assert_equal "abc", header[:id]
    assert_equal "/work", header[:cwd]
  end

  def test_read_header_is_nil_for_malformed_or_non_session_files
    bad_json = File.join(@dir, "bad.jsonl")
    File.write(bad_json, "{not json\n")
    not_a_session = File.join(@dir, "other.jsonl")
    File.write(not_a_session, "#{JSON.generate({ type: "note", id: "x" })}\n")
    missing = File.join(@dir, "gone.jsonl")

    assert_nil Truffle::Session.read_header(bad_json)
    assert_nil Truffle::Session.read_header(not_a_session)
    assert_nil Truffle::Session.read_header(missing)
  end

  def test_list_orders_sessions_newest_first_by_mtime
    now = Time.now
    write_session("old", mtime: now - 300)
    write_session("mid", mtime: now - 200)
    write_session("new", mtime: now - 100)

    ids = Truffle::Session.list(dir: @dir).map(&:id)

    assert_equal %w[new mid old], ids
  end

  def test_most_recent_returns_the_newest_path
    now = Time.now
    write_session("old", mtime: now - 300)
    newest = write_session("new", mtime: now - 100)

    assert_equal newest, Truffle::Session.most_recent(dir: @dir)
  end

  def test_list_filters_by_recorded_cwd_when_given
    write_session("here", cwd: "/work/project")
    write_session("elsewhere", cwd: "/work/other")

    ids = Truffle::Session.list(dir: @dir, cwd: "/work/project").map(&:id)

    assert_equal %w[here], ids
  end

  def test_list_skips_corrupt_files_but_keeps_valid_ones
    write_session("good")
    File.write(File.join(@dir, "corrupt.jsonl"), "{ broken\n")

    ids = Truffle::Session.list(dir: @dir).map(&:id)

    assert_equal %w[good], ids
  end

  def test_list_of_a_missing_directory_is_empty
    assert_empty Truffle::Session.list(dir: File.join(@dir, "nope"))
    assert_nil Truffle::Session.most_recent(dir: File.join(@dir, "nope"))
  end

  def test_list_without_cwd_or_dir_is_rejected
    assert_raises(ArgumentError) { Truffle::Session.list }
  end

  def test_cwd_defaults_the_directory_to_the_per_project_location
    Dir.mktmpdir("truffle-home") do |home|
      with_agent_dir(File.join(home, "agent")) do
        session = Truffle::Session.create(cwd: "/home/ada/proj")
        session.append_message(Truffle::Message.user("hi"))
        session.append_message(Truffle::Message.assistant(content: "hello"))

        assert_equal session.file, Truffle::Session.most_recent(cwd: "/home/ada/proj")
      end
    end
  end

  def with_agent_dir(dir)
    key = "TRUFFLE_AGENT_DIR"
    previous = ENV.fetch(key, :__absent__)
    ENV[key] = dir
    yield
  ensure
    previous == :__absent__ ? ENV.delete(key) : (ENV[key] = previous)
  end
end
