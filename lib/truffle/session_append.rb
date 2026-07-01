# frozen_string_literal: true

require "json"
require "time"
require "fileutils"
require_relative "uuid"

module Truffle
  # Private append/persistence helpers for Session.
  module SessionAppend
    private

    # Build an entry of the given type with the id/parent/timestamp envelope every
    # entry shares, then append it. For an already-flushed session, refresh the
    # file state under a lock first so resumed writers chain from the latest leaf.
    def append_typed(type, **fields)
      unless @flushed
        id = append_entry(new_entry(type, fields))
        @leaf_explicitly_set = false
        return id
      end

      @store.append do
        resync(preserve_leaf: @leaf_explicitly_set)
        entry = new_entry(type, fields)
        @entries << entry
        index(entry)
        @leaf_explicitly_set = false
        entry
      end
    end

    def new_entry(type, fields)
      { type: type, id: UUID.short(@by_id), parent_id: @leaf_id,
        timestamp: Time.now.utc.iso8601(3) }.merge(fields)
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

    def persist(_entry)
      flush if @assistant_entry_seen
    end

    # Reload the persisted state from the store and rebuild the in-memory index,
    # so an append chains from the latest leaf a concurrent writer may have added.
    # Runs inside the store's append lock. preserve_leaf keeps an explicitly set
    # leaf (a branch or reset) instead of snapping to the last entry.
    def resync(preserve_leaf:)
      leaf_id = @leaf_id if preserve_leaf
      state = @store.read
      unless state[:header][:id] == @id
        raise ArgumentError, "session id changed while resyncing #{@store.path}"
      end

      @entries = state[:entries]
      @by_id = {}
      @labels_by_id = {}
      @leaf_id = nil
      @assistant_entry_seen = false
      @entries.each { |entry| index(entry) }
      @leaf_id = leaf_id if preserve_leaf
    end

    def write_all_entries
      @store.write(header: @header, entries: @entries)
    end
  end
end
