# frozen_string_literal: true

module Truffle
  # Parse a CHANGELOG.md into version entries, ported from pi's changelog.ts
  # parsing surface (parseChangelog, compareVersions, getNewEntries). The scan
  # walks "## " headers, pulls a "[x.y.z]" (or bare "x.y.z") version out of each,
  # and collects the lines beneath it as that entry's content until the next
  # "## " header or the end of the file.
  #
  # pi's normalizeChangelogLinks is not ported: it rewrites relative markdown
  # links to pin them at earendil-works/pi's packages/coding-agent GitHub path per
  # release tag, which is specific to pi's monorepo layout and does not map to this
  # single-gem repo. pi's getChangelogPath is a config concern; parse takes an
  # explicit path.
  #
  #   entries = Truffle::Changelog.parse("CHANGELOG.md")
  #   entries.first.version # => "1.2.0"
  module Changelog
    # One parsed changelog section: its version components and its content (the
    # "## " header line followed by the section body, trimmed). `version` renders
    # the "major.minor.patch" string.
    Entry = Struct.new(:major, :minor, :patch, :content, keyword_init: true) do
      def version
        "#{major}.#{minor}.#{patch}"
      end
    end

    # The header of a section and the version captured from it. pi gates on the
    # "## " prefix first, then matches a version anywhere in the line, so
    # "## [1.2.3] - 2024-01-01" and "## 1.2.3" both parse while "## Unreleased"
    # does not.
    VERSION_HEADER = /##\s+\[?(\d+)\.(\d+)\.(\d+)\]?/

    module_function

    # Parse the changelog at `path` into entries in file order (a conventional
    # changelog lists newest first, so the entries come back newest first too). A
    # missing file yields an empty array. A "## " header whose version does not
    # parse ends the current section and starts no new one, so its body is dropped;
    # a preceding valid section is already saved and is kept. A read failure on an
    # existing file is swallowed to an empty array, matching pi's try/catch.
    def parse(path)
      return [] unless File.exist?(path)

      entries = []
      current = nil
      lines = []

      File.read(path).split("\n", -1).each do |line|
        if line.start_with?("## ")
          entries << build(current, lines) if current && !lines.empty?
          current = parse_version(line)
          lines = current ? [line] : []
        elsif current
          lines << line
        end
      end
      entries << build(current, lines) if current && !lines.empty?
      entries
    rescue SystemCallError => e
      warn "Warning: Could not parse changelog: #{e.message}"
      []
    end

    # Compare two entries by major, then minor, then patch, returning -1, 0, or 1.
    # pi's compareVersions returns the raw signed difference of the first differing
    # component; only its sign is ever consumed (a > 0 test in getNewEntries), so
    # this returns the sign directly, which is behaviorally identical everywhere.
    def compare_versions(left, right)
      [left.major, left.minor, left.patch] <=> [right.major, right.minor, right.patch]
    end

    # The entries strictly newer than a "x.y.z" baseline. Ports pi's getNewEntries,
    # including its lenient baseline parse: a missing component defaults to 0, so
    # "1.2" is read as 1.2.0 and "" as 0.0.0.
    def new_entries(entries, last_version)
      parts = last_version.split(".")
      baseline = Entry.new(
        major: (parts[0] || "0").to_i,
        minor: (parts[1] || "0").to_i,
        patch: (parts[2] || "0").to_i,
        content: ""
      )
      entries.select { |entry| compare_versions(entry, baseline).positive? }
    end

    # Build an entry from the collected lines: the header line and the body join
    # with newlines and the whole block is stripped, matching pi's
    # currentLines.join("\n").trim().
    def build(version, lines)
      Entry.new(**version, content: lines.join("\n").strip)
    end

    # The version components captured from a "## " header, or nil when the line
    # carries no parseable version.
    def parse_version(line)
      match = VERSION_HEADER.match(line)
      return nil unless match

      { major: match[1].to_i, minor: match[2].to_i, patch: match[3].to_i }
    end
  end
end
