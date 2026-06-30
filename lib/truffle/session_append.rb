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

      File.open(@file, File::RDWR) do |handle|
        handle.flock(File::LOCK_EX)
        refresh_from_file(preserve_leaf: @leaf_explicitly_set)
        entry = new_entry(type, fields)
        @entries << entry
        index(entry)
        @leaf_explicitly_set = false
        handle.seek(0, IO::SEEK_END)
        handle.write("#{JSON.generate(entry)}\n")
        entry[:id]
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

    def refresh_from_file(preserve_leaf:)
      leaf_id = @leaf_id if preserve_leaf
      fresh = self.class.load(@file)
      raise ArgumentError, "session id changed while refreshing #{@file}" unless fresh.id == @id

      @entries = fresh.entries
      @by_id = {}
      @labels_by_id = {}
      @leaf_id = nil
      @assistant_entry_seen = false
      @entries.each { |entry| index(entry) }
      @leaf_id = leaf_id if preserve_leaf
    end

    def write_all_entries
      FileUtils.mkdir_p(File.dirname(@file))
      File.open(@file, "wx") do |handle|
        handle.write("#{JSON.generate(@header)}\n")
        @entries.each { |entry| handle.write("#{JSON.generate(entry)}\n") }
      end
    end
  end
end
