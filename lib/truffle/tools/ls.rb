# frozen_string_literal: true

require_relative "path"
require_relative "truncate"

module Truffle
  module Tools
    # The ls engine, a native port of ls.ts's execute path. Nested so its helpers
    # do not collide with the other tools' flat helpers, the way Truncate, Path,
    # Find, and Edit are nested.
    module Ls
      DEFAULT_LIMIT = 500

      module_function

      def run(path:, limit:, cwd:)
        dir = Path.resolve(path.nil? || path.empty? ? "." : path, cwd)
        raise "Path not found: #{dir}" unless File.exist?(dir)
        raise "Not a directory: #{dir}" unless File.directory?(dir)

        # pi passes limit through untouched (no floor), so limit=0 breaks the loop
        # on the first entry and yields an empty listing.
        effective_limit = limit.nil? ? DEFAULT_LIMIT : limit.to_i
        entries = read_entries(dir)
        results, entry_limit_reached = collect(entries, dir, effective_limit)

        return "(empty directory)" if results.empty?

        render(results, effective_limit, entry_limit_reached)
      end

      # Dir.children excludes "." and "..", includes dotfiles, and returns the raw
      # entry names, matching Node's readdir. A read failure (permission denied on
      # a directory that stat reported) surfaces the way pi wraps its readdir throw.
      def read_entries(dir)
        Dir.children(dir)
      rescue SystemCallError => e
        raise "Cannot read directory: #{e.message}"
      end

      # Sort case-insensitively, then walk in order. pi sorts on the lowercased
      # name; the secondary sort on the raw name makes case-only ties deterministic
      # (JS localeCompare would leave them in filesystem order, which Ruby's sort is
      # not obligated to preserve). Each surviving entry is stat'd for the "/"
      # suffix; entries that cannot be stat'd (a broken symlink, say) are skipped,
      # matching pi's stat-throw-continue. The limit is checked before appending, so
      # a full listing stops at effective_limit entries and flags the overflow.
      def collect(entries, dir, effective_limit)
        sorted = entries.sort_by { |entry| [entry.downcase, entry] }
        results = []
        entry_limit_reached = false
        sorted.each do |entry|
          if results.length >= effective_limit
            entry_limit_reached = true
            break
          end
          suffix = directory_suffix(File.join(dir, entry))
          next if suffix.nil?

          results << (entry + suffix)
        end
        [results, entry_limit_reached]
      end

      # "/" for a directory, "" for anything else, nil when the entry cannot be
      # stat'd (the caller skips those). File.stat follows symlinks and raises on a
      # dangling target, mirroring pi's stat call.
      def directory_suffix(full_path)
        File.stat(full_path).directory? ? "/" : ""
      rescue SystemCallError
        nil
      end

      # Join the entries, byte-truncate at the shared 50KB ceiling (the entry count
      # is already bounded, so only bytes can truncate here), and append pi's
      # bracketed notices when a ceiling was hit.
      def render(results, effective_limit, entry_limit_reached)
        raw = results.join("\n")
        truncation = Truncate.head(raw, max_lines: Float::INFINITY)
        output = truncation.content
        notices = []
        if entry_limit_reached
          notices << "#{effective_limit} entries limit reached. " \
                     "Use limit=#{effective_limit * 2} for more"
        end
        if truncation.truncated
          notices << "#{Truncate.format_size(Truncate::DEFAULT_MAX_BYTES)} limit reached"
        end
        output += "\n\n[#{notices.join(". ")}]" unless notices.empty?
        output
      end
    end

    LS_DESCRIPTION =
      "List directory contents. Returns entries sorted alphabetically, with '/' " \
      "suffix for directories. Includes dotfiles. Output is truncated to " \
      "#{Ls::DEFAULT_LIMIT} entries or #{Truncate::DEFAULT_MAX_BYTES / 1024}KB " \
      "(whichever is hit first).".freeze

    # Build pi's `ls` tool, bound to a working directory. The model passes an
    # optional directory and an optional entry limit; the entries are returned one
    # per line, sorted case-insensitively, with a "/" suffix on directories and
    # dotfiles included. pi's TUI call and result rendering is out of scope.
    def self.ls(cwd: Dir.pwd)
      Tool.define("ls", LS_DESCRIPTION) do
        param :path, :string, "Directory to list (default: current directory)", required: false
        param :limit, :number, "Maximum number of entries to return (default: 500)", required: false
        run do |path: nil, limit: nil|
          Ls.run(path: path, limit: limit, cwd: cwd)
        end
      end
    end
  end
end
