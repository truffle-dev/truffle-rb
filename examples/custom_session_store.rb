# frozen_string_literal: true

# Back Truffle sessions with your own storage.
#
#   ruby examples/custom_session_store.rb
#   # or, on a host with no local Ruby:
#   script/rb ruby examples/custom_session_store.rb
#
# A session is normally a JSONL file, but Session only ever talks to its store
# through a small seam: #read, #write, #append, #exists?, and #path. Implement
# those against anything (a database, Redis, an object store) and a host app can
# keep conversations wherever it likes, with no persistence dependency inside
# Truffle. This store keeps entries in a plain array to show the shape; it is
# illustrative, not a shipped adapter.

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "truffle"

# The whole interface. A real store would put #read/#write/#append against its
# backend inside a transaction; the contract is only that #append holds the
# store consistent across the block so a concurrent writer chains from the same
# leaf, the way the file store uses flock.
class MemoryStore
  # Session#file delegates here, so give the store a stable identifier.
  attr_reader :path

  def initialize(name = "demo")
    @path = "memory://#{name}"
    @header = nil
    @entries = []
  end

  # Whether anything has been written yet. A buffered session flushes on its
  # first assistant turn, so this stays false until then.
  def exists? = !@header.nil?

  # The current persisted state, the way Session wants it back.
  def read = { header: @header, entries: @entries.map(&:dup) }

  # Persist a whole session at once (the flush of a buffered start). Create-once,
  # matching the file store, so a second write never clobbers history.
  def write(header:, entries:)
    raise "session already written" if @header

    @header = header.dup
    @entries = entries.map(&:dup)
  end

  # Append one entry. The block resyncs and mints the entry against the current
  # state and returns it; we store that entry and hand back its id. A backend
  # with real concurrency would wrap this block in a lock or transaction.
  def append
    entry = yield
    @entries << entry.dup
    entry[:id]
  end
end

store = MemoryStore.new
session = Truffle::Session.start(store: store, cwd: Dir.pwd)
session.append_message(Truffle::Message.user("what is the capital of France?"))
session.append_message(Truffle::Message.assistant(content: "Paris."))
session.append_message(Truffle::Message.user("and of Japan?"))
session.append_message(Truffle::Message.assistant(content: "Tokyo."))

puts "store id: #{session.file}"
puts "entries persisted: #{store.read[:entries].size}"
puts

# Reopen from the same store: the conversation comes back intact, no file in
# sight. This is exactly what Session.load does for the file store.
reopened = Truffle::Session.open(store)
reopened.messages.each do |message|
  puts "#{message.role.to_s.rjust(9)}: #{message.text}"
end
