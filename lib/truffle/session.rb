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
  # The file also carries settings entries (the active model and thinking level)
  # and a compaction entry (a summary that stands in for the turns before it).
  # #context walks the path and applies them: it recovers the live model and
  # thinking level and, when the path was compacted, returns the summary followed
  # by the kept tail instead of the full history. Branching to a second child,
  # branch summaries, labels, the deferred-first-flush optimization, and v1/v2
  # file migration are faithful follow-ups, not part of this slice.
  #
  #   session = Truffle::Session.create(dir: "/tmp/sessions", cwd: Dir.pwd)
  #   session.append_message(Truffle::Message.user("hello"))
  #   reloaded = Truffle::Session.load(session.file)
  #   reloaded.messages # => [#<Truffle::Message role=:user ...>]
  class Session
    # Bumped when the on-disk entry shape changes. New sessions are born at this
    # version; reading an older file is a migration follow-up.
    SESSION_VERSION = 3

    # Wrap the compaction summary so the model knows it is replacing earlier
    # turns. Ported verbatim from pi's transform of a compaction entry into a
    # user message (COMPACTION_SUMMARY_PREFIX/SUFFIX in messages.ts).
    COMPACTION_SUMMARY_PREFIX =
      "The conversation history before this point was compacted into the " \
      "following summary:\n\n<summary>\n"
    COMPACTION_SUMMARY_SUFFIX = "\n</summary>"

    # The model recorded by a model_change entry: which provider serves it and
    # the wire id it is named by.
    ModelRef = Struct.new(:provider, :model_id, keyword_init: true)

    # What a leaf-to-root walk reconstructs: the messages the model should see
    # (compaction applied), plus the thinking level and model in force at the leaf.
    Context = Struct.new(:messages, :thinking_level, :model, keyword_init: true)

    attr_reader :file, :id, :cwd, :parent_session, :tools, :leaf_id

    # Start a new session: mint an id (a time-ordered uuidv7 unless one is given),
    # write the header, and return a Session bound to the file so messages can be
    # appended. The file name carries the timestamp and id, with the colons and
    # dots of the ISO timestamp folded to dashes so it is path-safe, matching pi.
    #
    # tools records the names of the tools the producing agent had, so a resumed
    # agent can rebind its toolbox by name (Agent.dump/load). It is a Truffle
    # extension to pi's header and is omitted when empty, so a plain message
    # session is written exactly as pi writes it.
    def self.create(dir:, cwd:, id: nil, parent_session: nil, tools: nil, now: Time.now)
      id ||= UUID.v7
      timestamp = now.utc.iso8601(3)
      header = { type: "session", version: SESSION_VERSION, id: id, timestamp: timestamp, cwd: cwd }
      header[:parent_session] = parent_session if parent_session
      header[:tools] = tools if tools && !tools.empty?

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
      @tools = header[:tools]
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
      append_typed("message", message: message.to_h)
    end

    # Record which model is now in force. buildSessionContext reads the latest one
    # on the path so a resumed session restarts on the same model.
    def append_model_change(provider:, model_id:)
      append_typed("model_change", provider: provider, model_id: model_id)
    end

    # Record the thinking level now in force (pi's "off"/"low"/... string), read
    # back the same way as a model change.
    def append_thinking_level_change(level)
      append_typed("thinking_level_change", thinking_level: level)
    end

    # Record that the turns before first_kept_entry_id were compacted into a
    # summary. tokens_before is the size that was compacted away, kept for display.
    # After this, #context returns the summary plus the kept tail, not the full
    # history. The caller summarizes; the session only stores the marker.
    def append_compaction(summary:, first_kept_entry_id:, tokens_before:)
      append_typed(
        "compaction",
        summary: summary,
        first_kept_entry_id: first_kept_entry_id,
        tokens_before: tokens_before
      )
    end

    # Rebuild the raw message history by walking from a leaf back to the root and
    # turning each message entry back into a Message, oldest first. This is every
    # message on the path, ignoring compaction; #context applies compaction.
    def messages(leaf_id: @leaf_id)
      message_entries(path_to(leaf_id))
    end

    # Reconstruct what a resumed agent should start from: the messages to feed the
    # model (the compaction summary plus the kept tail when the path was compacted,
    # otherwise the whole history), and the thinking level and model in force at
    # the leaf. This is pi's buildSessionContext. (pi also lets an assistant
    # message carry the model; my Message has no provider/model field yet, so only
    # model_change entries set the model here.)
    def context(leaf_id: @leaf_id)
      path = path_to(leaf_id)
      thinking_level, model, compaction = scan_settings(path)
      Context.new(
        messages: build_messages(path, compaction),
        thinking_level: thinking_level,
        model: model
      )
    end

    private

    # Build an entry of the given type with the id/parent/timestamp envelope every
    # entry shares, then append it. The id and leaf are read now, at append time.
    def append_typed(type, **fields)
      append_entry(
        { type: type, id: UUID.short(@by_id), parent_id: @leaf_id,
          timestamp: Time.now.utc.iso8601(3) }.merge(fields)
      )
    end

    # Append a brand-new entry: record it in @entries, index it, and persist the
    # one line. The constructor indexes entries already in @entries, so the push
    # lives here and not in index, keeping the two paths from double-adding.
    def append_entry(entry)
      @entries << entry
      index(entry)
      File.open(@file, "a") { |handle| handle.write("#{JSON.generate(entry)}\n") }
      entry[:id]
    end

    # Walk from a leaf back to the root via parent_id, then reverse into
    # chronological order. An unknown or nil leaf yields an empty path.
    def path_to(leaf_id)
      path = []
      current = leaf_id ? @by_id[leaf_id] : nil
      while current
        path << current
        parent = current[:parent_id]
        current = parent ? @by_id[parent] : nil
      end
      path.reverse
    end

    # Turn the message entries on a path into Messages, dropping settings and
    # compaction entries (they shape the walk but are not messages themselves).
    def message_entries(entries)
      entries.filter_map do |entry|
        Message.from_h(entry[:message]) if entry[:type] == "message"
      end
    end

    # Find the thinking level and model in force at the leaf (the latest such
    # entry wins) and the compaction entry if the path has one.
    def scan_settings(path)
      thinking_level = "off"
      model = nil
      compaction = nil
      path.each do |entry|
        case entry[:type]
        when "thinking_level_change" then thinking_level = entry[:thinking_level]
        when "model_change" then model = model_ref(entry)
        when "compaction" then compaction = entry
        end
      end
      [thinking_level, model, compaction]
    end

    # Build a ModelRef from a model_change entry.
    def model_ref(entry)
      ModelRef.new(provider: entry[:provider], model_id: entry[:model_id])
    end

    # The messages to feed the model: every message when there was no compaction,
    # otherwise the summary followed by the kept tail.
    def build_messages(path, compaction)
      return message_entries(path) unless compaction

      [compaction_summary_message(compaction), *message_entries(kept_window(path, compaction))]
    end

    # The entries a compaction keeps: those from first_kept_entry_id up to the
    # compaction (its recent context), plus everything after it. If the kept id is
    # not on the path the kept head is empty, matching pi's foundFirstKept flag.
    def kept_window(path, compaction)
      idx = path.index { |entry| entry[:id] == compaction[:id] }
      before = path[0...idx]
      kept_start = before.index { |entry| entry[:id] == compaction[:first_kept_entry_id] }
      kept = kept_start ? before[kept_start..] : []
      kept + (path[(idx + 1)..] || [])
    end

    # The user message that stands in for the compacted turns.
    def compaction_summary_message(compaction)
      text = COMPACTION_SUMMARY_PREFIX + compaction[:summary] + COMPACTION_SUMMARY_SUFFIX
      Message.user(text)
    end

    # Record an entry in the id map and advance the leaf to it. Called once per
    # loaded entry by the constructor and once per appended entry.
    def index(entry)
      @by_id[entry[:id]] = entry
      @leaf_id = entry[:id]
    end
  end
end
