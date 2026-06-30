# frozen_string_literal: true

require "json"
require "fileutils"
require "securerandom"
require_relative "uuid"

module Truffle
  # Upgrades older session JSONL records to the current on-disk shape.
  module SessionMigration
    module_function

    HEADER_KEY_RENAMES = { parentSession: :parent_session }.freeze
    ENTRY_KEY_RENAMES = {
      parentId: :parent_id,
      thinkingLevel: :thinking_level,
      modelId: :model_id,
      firstKeptEntryId: :first_kept_entry_id,
      firstKeptEntryIndex: :first_kept_entry_index,
      tokensBefore: :tokens_before,
      fromId: :from_id,
      targetId: :target_id
    }.freeze

    def migrate_to_current_version(records, current_version:)
      header = records.first
      changed = normalize_keys(header, HEADER_KEY_RENAMES)
      records.drop(1).each do |entry|
        changed = true if normalize_keys(entry, ENTRY_KEY_RENAMES)
        changed = true if normalize_legacy_message?(entry)
      end

      version = Integer(header[:version] || 1, exception: false) || 1
      if version < 2
        migrate_v1_to_v2(records)
        changed = true
      end

      if header[:version] != current_version
        header[:version] = current_version
        changed = true
      end

      changed
    end

    def rewrite_file(path, records)
      dir = File.dirname(path)
      basename = File.basename(path)
      mode = File.stat(path).mode & 0o777
      tmp_path = File.join(dir, ".#{basename}.#{Process.pid}.#{SecureRandom.hex(8)}.tmp")

      File.open(tmp_path, File::WRONLY | File::CREAT | File::EXCL, mode) do |handle|
        records.each { |record| handle.write("#{JSON.generate(record)}\n") }
        handle.flush
        handle.fsync
      end
      File.chmod(mode, tmp_path)

      FileUtils.cp(path, "#{path}.bak", preserve: true)
      File.rename(tmp_path, path)
    ensure
      FileUtils.rm_f(tmp_path) if tmp_path && File.exist?(tmp_path)
    end

    def normalize_keys(hash, renames)
      changed = false
      renames.each do |old_key, new_key|
        next unless hash.key?(old_key)

        hash[new_key] = hash[old_key] unless hash.key?(new_key)
        hash.delete(old_key)
        changed = true
      end
      changed
    end

    def normalize_legacy_message?(entry)
      message = entry[:message]
      return false unless message.is_a?(Hash)

      content = message["content"]
      if content.is_a?(String)
        message["content"] = [{ "type" => "text", "text" => content }]
        return true
      end

      return false unless content.is_a?(Array) && content.any?(String)

      message["content"] = content.map do |block|
        block.is_a?(String) ? { "type" => "text", "text" => block } : block
      end
      true
    end

    def migrate_v1_to_v2(records)
      used = {}
      previous_id = nil
      records.each do |entry|
        next if entry[:type] == "session"

        entry[:id] ||= UUID.short(used)
        used[entry[:id]] = true
        entry[:parent_id] = previous_id unless entry.key?(:parent_id)
        previous_id = entry[:id]
        migrate_compaction_kept_index(entry, records) if entry[:type] == "compaction"
      end
    end

    def migrate_compaction_kept_index(entry, records)
      return unless entry.key?(:first_kept_entry_index)

      target = records[entry[:first_kept_entry_index]]
      entry[:first_kept_entry_id] = target[:id] if target && target[:type] != "session"
      entry.delete(:first_kept_entry_index)
    end
  end
end
