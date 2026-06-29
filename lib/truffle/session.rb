# frozen_string_literal: true

require "json"
require "time"
require "fileutils"
require_relative "uuid"
require_relative "message"

module Truffle
  # An append-only session store, ported from pi's session manager. A session is
  # a JSONL file: the first line is a header, and every line after it is an entry
  # with its own id, the id of its parent, and a timestamp. Entries chain through
  # parent_id, so a session is a tree and the current conversation is the path
  # from a leaf back to the root. This is what lets an agent pause and resume: the
  # message history is the file, and reloading it rebuilds the same Message list.
  #
  # This is the linear spine of pi's manager: a header, message entries appended
  # in order, and a leaf-to-root walk that reconstructs the messages. Branching to
  # a second child, settings entries (model and thinking-level changes),
  # compaction and branch summaries, labels, the deferred-first-flush optimization,
  # and v1/v2 file migration are faithful follow-ups, not part of this slice.
  #
  #   session = Truffle::Session.create(dir: "/tmp/sessions", cwd: Dir.pwd)
  #   session.append_message(Truffle::Message.user("hello"))
  #   reloaded = Truffle::Session.load(session.file)
  #   reloaded.messages # => [#<Truffle::Message role=:user ...>]
  class Session
    # Bumped when the on-disk entry shape changes. New sessions are born at this
    # version; reading an older file is a migration follow-up.
    SESSION_VERSION = 3

    attr_reader :file, :id, :cwd, :parent_session, :leaf_id

    # Start a new session: mint an id (a time-ordered uuidv7 unless one is given),
    # write the header, and return a Session bound to the file so messages can be
    # appended. The file name carries the timestamp and id, with the colons and
    # dots of the ISO timestamp folded to dashes so it is path-safe, matching pi.
    def self.create(dir:, cwd:, id: nil, parent_session: nil, now: Time.now)
      id ||= UUID.v7
      timestamp = now.utc.iso8601(3)
      header = { type: "session", version: SESSION_VERSION, id: id, timestamp: timestamp, cwd: cwd }
      header[:parent_session] = parent_session if parent_session

      FileUtils.mkdir_p(dir)
      file = File.join(dir, "#{timestamp.gsub(/[:.]/, "-")}_#{id}.jsonl")
      File.open(file, "wx") { |handle| handle.write("#{JSON.generate(header)}\n") }

      new(file: file, header: header, entries: [])
    end

    # Read a session file back: parse each JSONL line, skipping any that do not
    # parse (pi tolerates a truncated final write), then require the first entry
    # to be a valid session header. The returned Session is bound to the same
    # file, so a resumed conversation keeps appending to it.
    def self.load(path)
      parsed = File.read(path).each_line.filter_map { |line| parse_line(line) }
      header = parsed.first
      unless header && header[:type] == "session" && header[:id].is_a?(String)
        raise ArgumentError, "not a valid Truffle session: #{path}"
      end

      new(file: path, header: header, entries: parsed.drop(1))
    end

    # Parse one JSONL line into an entry with symbol top-level keys. The nested
    # message Hash keeps its string keys; Message.from_h folds them. Blank and
    # malformed lines return nil so the caller drops them.
    def self.parse_line(line)
      return nil if line.strip.empty?

      JSON.parse(line).transform_keys(&:to_sym)
    rescue JSON::ParserError
      nil
    end
    private_class_method :parse_line

    def initialize(file:, header:, entries:)
      @file = file
      @header = header
      @id = header[:id]
      @cwd = header[:cwd]
      @parent_session = header[:parent_session]
      @entries = entries
      @by_id = {}
      @leaf_id = nil
      entries.each { |entry| index(entry) }
    end

    # The session version recorded in the header.
    def version
      @header[:version]
    end

    # The entries after the header, in file order (a defensive copy).
    def entries
      @entries.dup
    end

    # Append a message as a child of the current leaf, then advance the leaf.
    # Returns the new entry id. The Message is stored as its #to_h so it round
    # trips through JSON without the session knowing block shapes.
    def append_message(message)
      append_entry(
        type: "message",
        id: UUID.short(@by_id),
        parent_id: @leaf_id,
        timestamp: Time.now.utc.iso8601(3),
        message: message.to_h
      )
    end

    # Rebuild the message history by walking from a leaf back to the root and
    # reversing into chronological order, then turning each message entry back
    # into a Message. With no branching this is the whole conversation; with a
    # leaf id it is the path to that point. Defaults to the current leaf.
    def messages(leaf_id: @leaf_id)
      return [] if leaf_id.nil?

      path = []
      current = @by_id[leaf_id]
      while current
        path << current
        parent = current[:parent_id]
        current = parent ? @by_id[parent] : nil
      end

      path.reverse.filter_map do |entry|
        Message.from_h(entry[:message]) if entry[:type] == "message"
      end
    end

    private

    # Append a brand-new entry: record it in @entries, index it, and persist the
    # one line. The constructor indexes entries already in @entries, so the push
    # lives here and not in index, keeping the two paths from double-adding.
    def append_entry(entry)
      @entries << entry
      index(entry)
      File.open(@file, "a") { |handle| handle.write("#{JSON.generate(entry)}\n") }
      entry[:id]
    end

    # Record an entry in the id map and advance the leaf to it. Called once per
    # loaded entry by the constructor and once per appended entry.
    def index(entry)
      @by_id[entry[:id]] = entry
      @leaf_id = entry[:id]
    end
  end
end
