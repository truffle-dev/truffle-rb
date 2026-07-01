# frozen_string_literal: true

require "json"
require "fileutils"
require_relative "../session_migration"

module Truffle
  class Session
    # The default session store: a JSONL file, one header line and one line per
    # entry. It is the reference conformer of the store seam Session talks to, so
    # a host that wants sessions in a database implements the same handful of
    # methods (#read, #write, #append, #exists?, #path) against its own backend
    # without truffle taking a persistence dependency.
    #
    # The JSONL format, the tolerance for an interrupted final line, and the
    # v1/v2 migration are this store's own concern, kept out of the interface so a
    # database store carries none of them. The #32 flock/leaf-refresh contract
    # lives in #append: it holds an exclusive lock across the whole block so a
    # concurrent writer chains from a consistent leaf.
    class FileStore
      # A stable identifier for the store, here the file path. Session#file
      # delegates to it, so callers that read the JSONL directly keep working.
      attr_reader :path

      def initialize(path)
        @path = path
      end

      # Whether the backing file has been written yet. A freshly created session
      # buffers in memory until its first assistant turn, so this is false until
      # then.
      def exists? = File.exist?(@path)

      # Parse the file into { header:, entries: }, tolerating a malformed final
      # line because it may be an interrupted append, and rejecting earlier
      # malformed lines because dropping one would break the parent_id chain.
      # Old v1/v2 files are migrated to the current shape and rewritten in place,
      # so a resumed session reads today's entry shape.
      def read
        lines = File.read(@path).each_line.to_a
        final_index = lines.rindex { |line| !line.strip.empty? }
        records = lines.each_with_index.filter_map do |line, index|
          parse_line(line, final_entry: index == final_index, line_number: index + 1)
        end

        if SessionMigration.migrate_to_current_version(records, current_version: SESSION_VERSION)
          SessionMigration.rewrite_file(@path, records)
        end

        { header: records.first, entries: records.drop(1) }
      end

      # Write a header and its entries as a fresh file, failing if one already
      # exists. This is the flush of a buffered session, which is only ever a new
      # file, so create-once matches pi and guards against clobbering history.
      def write(header:, entries:)
        FileUtils.mkdir_p(File.dirname(@path))
        File.open(@path, "wx") do |handle|
          handle.write("#{JSON.generate(header)}\n")
          entries.each { |entry| handle.write("#{JSON.generate(entry)}\n") }
        end
      end

      # Append one entry under an exclusive lock. The block runs while the lock is
      # held: it resyncs from disk and mints the entry so a concurrent writer's
      # entries are seen and chained from, then returns the entry to persist. We
      # write that one line and return its id.
      def append
        File.open(@path, File::RDWR) do |handle|
          handle.flock(File::LOCK_EX)
          entry = yield
          handle.seek(0, IO::SEEK_END)
          handle.write("#{JSON.generate(entry)}\n")
          entry[:id]
        end
      end

      private

      # Parse one JSONL line. Blank lines return nil; a malformed final line is
      # treated as a partial append, while a malformed earlier line raises.
      def parse_line(line, final_entry:, line_number:)
        return nil if line.strip.empty?

        JSON.parse(line).transform_keys(&:to_sym)
      rescue JSON::ParserError => e
        return nil if final_entry

        raise ArgumentError, "malformed session line #{line_number} in #{@path}: #{e.message}"
      end
    end
  end
end
