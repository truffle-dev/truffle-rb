# frozen_string_literal: true

require "json"
require "time"
require "fileutils"
require_relative "uuid"
require_relative "message"
require_relative "usage"
require_relative "session_migration"

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
  # by the kept tail instead of the full history. New sessions buffer their first
  # entries until an assistant message arrives, so abandoned one-user-turn starts
  # do not leave files behind; .flush forces the write when a caller explicitly
  # wants a partial session persisted. Old v1/v2 files are migrated to the current
  # tree shape on load.
  #
  # Because entries form a tree, #branch and #reset_leaf can move the leaf back
  # before the next append opens a second child. Branch summaries and labels ride
  # along as entries while staying out of normal message history.
  class Session
    # Bumped when the on-disk entry shape changes. New sessions are born at this
    # version; older v1/v2 files are upgraded by .load.
    SESSION_VERSION = 3

    # Wrap the compaction summary so the model knows it is replacing earlier
    # turns. Ported verbatim from pi's transform of a compaction entry into a
    # user message (COMPACTION_SUMMARY_PREFIX/SUFFIX in messages.ts).
    COMPACTION_SUMMARY_PREFIX =
      "The conversation history before this point was compacted into the " \
      "following summary:\n\n<summary>\n"
    COMPACTION_SUMMARY_SUFFIX = "\n</summary>"

    # Wrap a branch summary so the model knows it is reading a digest of a path
    # the conversation branched away from and came back past. Ported verbatim from
    # pi's BRANCH_SUMMARY_PREFIX/SUFFIX in messages.ts. Unlike a compaction summary,
    # a branch summary is a real entry on the path and folds into context inline.
    BRANCH_SUMMARY_PREFIX =
      "The following is a summary of a branch that this conversation came back " \
      "from:\n\n<summary>\n"
    BRANCH_SUMMARY_SUFFIX = "\n</summary>"

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

      file = File.join(dir, "#{timestamp.gsub(/[:.]/, "-")}_#{id}.jsonl")

      new(file: file, header: header, entries: [], flushed: false)
    end

    # Read a session file back: parse each JSONL line, tolerating a malformed
    # final line because it may be an interrupted append. Earlier malformed lines
    # are rejected because dropping one would break the parent_id chain and hide
    # history loss. The returned Session is bound to the same file, so a resumed
    # conversation keeps appending to it.
    def self.load(path)
      lines = File.read(path).each_line.to_a
      final_entry_index = lines.rindex { |line| !line.strip.empty? }
      parsed = lines.each_with_index.filter_map do |line, index|
        parse_line(line, final_entry: index == final_entry_index,
                         line_number: index + 1, path: path)
      end
      header = parsed.first
      unless header && header[:type] == "session" && header[:id].is_a?(String)
        raise ArgumentError, "not a valid Truffle session: #{path}"
      end

      if SessionMigration.migrate_to_current_version(parsed, current_version: SESSION_VERSION)
        SessionMigration.rewrite_file(path, parsed)
      end

      new(file: path, header: header, entries: parsed.drop(1), flushed: true)
    end

    # Parse one JSONL line. Blank lines return nil; a malformed final line is
    # treated as a partial append, while malformed earlier lines raise.
    def self.parse_line(line, final_entry:, line_number:, path:)
      return nil if line.strip.empty?

      JSON.parse(line).transform_keys(&:to_sym)
    rescue JSON::ParserError => e
      return nil if final_entry

      raise ArgumentError, "malformed session line #{line_number} in #{path}: #{e.message}"
    end
    private_class_method :parse_line

    def initialize(file:, header:, entries:, flushed: true)
      @file = file
      @header = header
      @id = header[:id]
      @cwd = header[:cwd]
      @parent_session = header[:parent_session]
      @tools = header[:tools]
      @entries = entries
      @by_id = {}
      @labels_by_id = {}
      @leaf_id = nil
      @flushed = flushed
      @assistant_entry_seen = false
      entries.each { |entry| index(entry) }
    end

    # The session version recorded in the header.
    def version = @header[:version]

    # The entries after the header, in file order (a defensive copy).
    def entries = @entries.dup

    # Force any buffered header/entries to disk. This keeps the pi optimization
    # for normal runs while letting explicit persistence paths (Agent#dump, tests,
    # host apps) save a partial conversation.
    def flush
      return self if @flushed

      write_all_entries
      @flushed = true
      self
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

    # Record the accumulated usage seen by an agent at a persistence checkpoint.
    # It stays out of model context; Agent.load reads the latest entry on the
    # active path and continues accounting from there.
    def append_usage(usage) = append_typed("usage", usage: usage.to_h)

    # Record that the turns before first_kept_entry_id were compacted into a
    # summary. tokens_before is the size that was compacted away, kept for display.
    # After this, #context returns the summary plus the kept tail, not the full
    # history. The caller summarizes; the session only stores the marker.
    #
    # details, when given, is the read/modified file lists the compacted history
    # touched (Compaction's CompactionResult#details). A later compaction reads it
    # off the prior compaction entry to carry those file operations forward, the
    # way pi seeds file ops from a previous CompactionEntry. It is omitted when
    # nil, so a compaction without file metadata is written exactly as pi writes one.
    def append_compaction(summary:, first_kept_entry_id:, tokens_before:, details: nil)
      fields = {
        summary: summary,
        first_kept_entry_id: first_kept_entry_id,
        tokens_before: tokens_before
      }
      fields[:details] = details if details
      append_typed("compaction", **fields)
    end

    # Build the context for a leaf-to-root path that has already been resolved
    # into chronological order: the messages to feed the model (the compaction
    # summary plus the kept tail when the path was compacted, otherwise the whole
    # history), and the thinking level and model in force at the path's leaf. This
    # is the pure half of pi's buildSessionContext, taking entries rather than a
    # leaf id, so compaction can compute a path's effective context size without a
    # bound session. (pi also lets an assistant message carry the model; my Message
    # has no provider/model field yet, so only model_change entries set the model.)
    def self.build_context(path)
      thinking_level, model, compaction = scan_settings(path)
      Context.new(
        messages: build_messages(path, compaction),
        thinking_level: thinking_level,
        model: model
      )
    end

    # Rebuild the raw message history by walking from a leaf back to the root and
    # turning each message entry back into a Message, oldest first. This is every
    # message on the path, ignoring compaction; #context applies compaction.
    def messages(leaf_id: @leaf_id)
      self.class.message_entries(path_to(leaf_id))
    end

    # Reconstruct what a resumed agent should start from, for the conversation
    # ending at leaf_id. Resolves the path, then defers to build_context.
    def context(leaf_id: @leaf_id)
      self.class.build_context(path_to(leaf_id))
    end

    # The latest accumulated-usage snapshot on the active path, or zero when a
    # session predates usage persistence.
    def usage(leaf_id: @leaf_id) = usage_from(path_to(leaf_id))

    # Move the leaf back to an earlier entry so the next append becomes a second
    # child of it, opening a new branch while the abandoned path stays on disk
    # unchanged. #messages and #context follow the leaf, so they reflect the new
    # branch immediately. Ports pi's SessionManager#branch; raises if the id is
    # not an entry in this session.
    def branch(entry_id)
      raise ArgumentError, "entry not found: #{entry_id}" unless @by_id.key?(entry_id)

      @leaf_id = entry_id
    end

    # Branch like #branch, but also drop a branch_summary entry on the new path
    # that carries a digest of the abandoned turns forward. The summary becomes a
    # user message in #context (wrapped in BRANCH_SUMMARY_PREFIX/SUFFIX) so the
    # model sees what the path it came back past contained, while the abandoned
    # entries themselves stay out of context. Pass nil to branch from the root.
    # details rides along for callers but is never sent to the model; it is
    # omitted from the entry when nil, matching #append_compaction. Ports pi's
    # SessionManager#branchWithSummary; raises if branch_from_id is not an entry.
    def branch_with_summary(branch_from_id, summary, details: nil)
      unless branch_from_id.nil? || @by_id.key?(branch_from_id)
        raise ArgumentError, "entry not found: #{branch_from_id}"
      end

      @leaf_id = branch_from_id
      fields = { from_id: branch_from_id || "root", summary: summary }
      fields[:details] = details unless details.nil?
      append_typed("branch_summary", **fields)
    end

    # Reset the leaf to before any entry, so the next append starts a fresh root
    # (parent_id nil). Used to re-edit the very first message. Ports pi's
    # SessionManager#resetLeaf.
    def reset_leaf
      @leaf_id = nil
    end

    # The entry with this id, or nil. Ports pi's getEntry.
    def entry(entry_id)
      @by_id[entry_id]
    end

    # The direct children of an entry, in file order: every entry whose parent_id
    # is parent_id. Pass nil for the root entries. More than one child means the
    # node was branched. Ports pi's getChildren.
    def children(parent_id)
      @entries.select { |candidate| candidate[:parent_id] == parent_id }
    end

    # Set or clear a user label (a bookmark) on an entry. The label is appended as
    # its own entry, so it advances the leaf like any append but never enters the
    # model's context; the resolved label is updated in the index, last write
    # winning. A nil or empty label clears it (the entry omits the label field,
    # as pi drops an undefined one). Ports pi's appendLabelChange; raises if the
    # target id is not an entry here. Returns the new label entry's id.
    def append_label_change(target_id, label)
      raise ArgumentError, "entry not found: #{target_id}" unless @by_id.key?(target_id)

      fields = { target_id: target_id }
      fields[:label] = label if label && !label.empty?
      append_typed("label", **fields)
    end

    # The resolved label on an entry, or nil. Ports pi's getLabel.
    def label(entry_id)
      @labels_by_id[entry_id]
    end

    # Turn the entries on a path into Messages, dropping settings and compaction
    # entries (they shape the walk but are not messages themselves). A message
    # entry yields its stored message; a branch_summary entry folds in inline as
    # a user message, matching pi's _buildContextMessages walk.
    def self.message_entries(entries)
      entries.filter_map do |entry|
        case entry[:type]
        when "message" then Message.from_h(entry[:message])
        when "branch_summary" then branch_summary_message(entry)
        end
      end
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
      persist(entry)
      entry[:id]
    end

    def persist(entry)
      unless assistant_entry_seen?
        append_line(entry) if @flushed
        return
      end

      @flushed ? append_line(entry) : flush
    end

    def assistant_entry_seen?
      @assistant_entry_seen
    end

    def append_line(entry)
      File.open(@file, "a") { |handle| handle.write("#{JSON.generate(entry)}\n") }
    end

    def write_all_entries
      FileUtils.mkdir_p(File.dirname(@file))
      File.open(@file, "wx") do |handle|
        handle.write("#{JSON.generate(@header)}\n")
        @entries.each { |entry| handle.write("#{JSON.generate(entry)}\n") }
      end
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

    # Find the thinking level and model in force at the leaf (the latest such
    # entry wins) and the compaction entry if the path has one.
    def self.scan_settings(path)
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
    private_class_method :scan_settings

    # Build a ModelRef from a model_change entry.
    def self.model_ref(entry)
      ModelRef.new(provider: entry[:provider], model_id: entry[:model_id])
    end
    private_class_method :model_ref

    # The messages to feed the model: every message when there was no compaction,
    # otherwise the summary followed by the kept tail.
    def self.build_messages(path, compaction)
      return message_entries(path) unless compaction

      [compaction_summary_message(compaction), *message_entries(kept_window(path, compaction))]
    end
    private_class_method :build_messages

    # The entries a compaction keeps: those from first_kept_entry_id up to the
    # compaction (its recent context), plus everything after it. If the kept id is
    # not on the path the kept head is empty, matching pi's foundFirstKept flag.
    def self.kept_window(path, compaction)
      idx = path.index { |entry| entry[:id] == compaction[:id] }
      before = path[0...idx]
      kept_start = before.index { |entry| entry[:id] == compaction[:first_kept_entry_id] }
      kept = kept_start ? before[kept_start..] : []
      kept + (path[(idx + 1)..] || [])
    end
    private_class_method :kept_window

    # The user message that stands in for the compacted turns.
    def self.compaction_summary_message(compaction)
      text = COMPACTION_SUMMARY_PREFIX + compaction[:summary] + COMPACTION_SUMMARY_SUFFIX
      Message.user(text)
    end
    private_class_method :compaction_summary_message

    # The user message a branch_summary entry folds into context as.
    def self.branch_summary_message(entry)
      text = BRANCH_SUMMARY_PREFIX + entry[:summary] + BRANCH_SUMMARY_SUFFIX
      Message.user(text)
    end
    private_class_method :branch_summary_message

    def usage_from(path)
      entry = path.reverse.find { |candidate| candidate[:type] == "usage" }
      entry ? Usage.from_h(entry[:usage]) : Usage.zero
    end

    # Record an entry in the id map and advance the leaf to it, and resolve a
    # label entry into the label index. Called once per loaded entry by the
    # constructor and once per appended entry, so labels survive a reload.
    def index(entry)
      @by_id[entry[:id]] = entry
      @leaf_id = entry[:id]
      @assistant_entry_seen = true if message_role(entry) == "assistant"
      apply_label(entry[:target_id], entry[:label]) if entry[:type] == "label"
    end

    # Read the role directly from the serialized entry. Persistence must tolerate
    # future content block shapes that full Message parsing would reject.
    def message_role(entry)
      return nil unless entry[:type] == "message"

      message = entry[:message]
      return nil unless message.respond_to?(:[])

      (message[:role] || message["role"]).to_s
    end

    # Apply one label entry to the resolved-label index: a present label sets the
    # bookmark on its target, a nil or empty one clears it. Mirrors pi's
    # last-match-wins label resolution in _buildIndex.
    def apply_label(target_id, label)
      if label && !label.empty?
        @labels_by_id[target_id] = label
      else
        @labels_by_id.delete(target_id)
      end
    end
  end
end
