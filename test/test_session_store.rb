# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

# The pluggable store seam (#55). Session talks to persistence through a small
# interface (#read, #write, #append, #exists?, #path) so a host can back
# conversations with a database or anything else without truffle taking a
# dependency. FileStore is the default conformer; these drive Session through a
# hand-rolled in-memory store to prove the seam is real and to pin the guards the
# store contract relies on.
class TestSessionStore < Minitest::Test
  # A minimal conforming store that keeps everything in memory. Mirrors the shape
  # of examples/custom_session_store.rb; #appends counts calls so a test can see
  # the append path actually went through the store.
  class MemoryStore
    attr_reader :path, :appends

    def initialize(path: "memory://test")
      @path = path
      @header = nil
      @entries = []
      @appends = 0
    end

    def exists? = !@header.nil?

    def read = { header: @header, entries: @entries.map(&:dup) }

    def write(header:, entries:)
      raise "session already written" if @header

      @header = header.dup
      @entries = entries.map(&:dup)
    end

    def append
      @appends += 1
      entry = yield
      @entries << entry.dup
      entry[:id]
    end

    # Test-only: force the persisted header id to something else, so the next
    # resync sees a store that no longer matches this session.
    def corrupt_header_id!(id)
      @header = @header.merge(id: id)
    end
  end

  def setup
    @dir = Dir.mktmpdir("truffle-session-store")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def flushed_session(store)
    session = Truffle::Session.start(store: store, cwd: "/work")
    session.append_message(Truffle::Message.user("hello"))
    session.append_message(Truffle::Message.assistant(content: "hi"))
    session
  end

  def test_start_and_open_round_trip_through_a_custom_store
    store = MemoryStore.new
    flushed_session(store)

    reopened = Truffle::Session.open(store)
    roles = reopened.messages.map(&:role)

    assert_equal %i[user assistant], roles
    assert_equal "hi", reopened.messages.last.text
  end

  def test_file_delegates_to_the_store_path
    store = MemoryStore.new(path: "memory://xyz")
    session = Truffle::Session.start(store: store, cwd: "/work")

    assert_equal "memory://xyz", session.file
  end

  def test_appends_go_through_the_store_append_lock
    store = MemoryStore.new
    session = Truffle::Session.start(store: store, cwd: "/work")
    session.append_message(Truffle::Message.user("hello"))
    session.append_message(Truffle::Message.assistant(content: "hi"))

    # The first two appends buffer and flush together; every append after the
    # flush is one call through the store's #append.
    session.append_message(Truffle::Message.user("again"))

    assert_equal 1, store.appends
  end

  def test_open_rejects_a_store_without_a_session_header
    store = MemoryStore.new
    store.write(header: { type: "not_a_session", id: "abc" }, entries: [])

    error = assert_raises(ArgumentError) { Truffle::Session.open(store) }

    assert_match(/not a valid Truffle session/, error.message)
  end

  def test_open_rejects_a_header_whose_id_is_not_a_string
    store = MemoryStore.new
    store.write(header: { type: "session", id: 42 }, entries: [])

    assert_raises(ArgumentError) { Truffle::Session.open(store) }
  end

  def test_append_rejects_a_store_whose_session_id_changed
    store = MemoryStore.new
    session = flushed_session(store)
    store.corrupt_header_id!("someone-elses-session")

    error = assert_raises(ArgumentError) do
      session.append_message(Truffle::Message.user("next"))
    end

    assert_match(/session id changed/, error.message)
  end

  def test_a_second_session_append_chains_from_a_concurrent_entry
    store = MemoryStore.new
    first = flushed_session(store)
    second = Truffle::Session.open(store)

    first.append_message(Truffle::Message.user("from first"))
    second.append_message(Truffle::Message.user("from second"))

    # second resynced under the store's append, so its entry chains from first's
    # rather than opening a stale branch: the reopened path holds all four.
    roles = Truffle::Session.open(store).messages.map(&:text)

    assert_equal ["hello", "hi", "from first", "from second"], roles
  end

  def test_file_store_write_refuses_to_clobber_an_existing_file
    path = File.join(@dir, "session.jsonl")
    store = Truffle::Session::FileStore.new(path)
    store.write(header: { type: "session", id: "a" }, entries: [])

    assert_raises(Errno::EEXIST) do
      store.write(header: { type: "session", id: "b" }, entries: [])
    end
  end

  def test_file_store_exists_tracks_the_backing_file
    path = File.join(@dir, "session.jsonl")
    store = Truffle::Session::FileStore.new(path)

    refute_predicate store, :exists?

    store.write(header: { type: "session", id: "a" }, entries: [])

    assert_predicate store, :exists?
  end
end
