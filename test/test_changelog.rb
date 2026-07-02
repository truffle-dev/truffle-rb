# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "stringio"

# Changelog parsing, a port of pi's changelog.ts surface (parseChangelog,
# compareVersions, getNewEntries). "## [x.y.z]" headers open sections whose body
# runs to the next "## " header or EOF; entries come back in file order. Fixtures
# live in a temp dir so the suite stays hermetic.
class TestChangelog < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("truffle-changelog")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def write_changelog(text)
    path = File.join(@dir, "CHANGELOG.md")
    File.write(path, text)
    path
  end

  def entry(major, minor, patch, content = "")
    Truffle::Changelog::Entry.new(major: major, minor: minor, patch: patch, content: content)
  end

  def test_entry_reports_its_version_string
    assert_equal "1.2.3", entry(1, 2, 3).version
  end

  def test_missing_file_yields_no_entries
    assert_empty Truffle::Changelog.parse(File.join(@dir, "nope.md"))
  end

  def test_missing_file_is_silent
    # pi's existsSync check returns [] before the read, so a missing file never
    # trips the read-failure warning. The File.exist? guard preserves that: drop
    # it and the read raises, the rescue warns, and this goes red.
    original = $stderr
    $stderr = StringIO.new
    Truffle::Changelog.parse(File.join(@dir, "nope.md"))
    captured = $stderr.string
    $stderr = original

    assert_empty captured
  end

  def test_parses_bracketed_and_bare_headers_in_file_order
    path = write_changelog(<<~MD)
      # Changelog

      ## [1.2.0] - 2024-02-01
      - added a thing

      ## 1.1.0
      - older thing
    MD
    entries = Truffle::Changelog.parse(path)

    assert_equal([[1, 2, 0], [1, 1, 0]], entries.map { |e| [e.major, e.minor, e.patch] })
  end

  def test_content_keeps_the_header_line_and_trims_the_section
    path = write_changelog(<<~MD)
      ## [1.0.0]
      - first

      ## [0.9.0]
      - old
    MD
    entries = Truffle::Changelog.parse(path)

    assert_equal "## [1.0.0]\n- first", entries.first.content
  end

  def test_unparseable_header_drops_its_body_but_keeps_the_prior_entry
    path = write_changelog(<<~MD)
      ## [1.0.0]
      - shipped

      ## Unreleased
      - not versioned yet
    MD
    entries = Truffle::Changelog.parse(path)

    assert_equal 1, entries.length
    assert_equal [1, 0, 0], [entries.first.major, entries.first.minor, entries.first.patch]
    refute_includes entries.first.content, "not versioned yet"
  end

  def test_lines_before_the_first_version_header_are_ignored
    path = write_changelog(<<~MD)
      # Changelog

      Everything up here is preamble.

      ## [2.0.0]
      - real entry
    MD
    entries = Truffle::Changelog.parse(path)

    assert_equal 1, entries.length
    assert_equal "## [2.0.0]\n- real entry", entries.first.content
  end

  def test_compare_versions_orders_by_major_then_minor_then_patch
    assert_equal(-1, Truffle::Changelog.compare_versions(entry(1, 0, 0), entry(2, 0, 0)))
    assert_equal 1, Truffle::Changelog.compare_versions(entry(1, 3, 0), entry(1, 2, 9))
    assert_equal(-1, Truffle::Changelog.compare_versions(entry(1, 2, 3), entry(1, 2, 4)))
    assert_equal 0, Truffle::Changelog.compare_versions(entry(1, 2, 3), entry(1, 2, 3))
  end

  def test_new_entries_returns_only_entries_past_the_baseline
    entries = [entry(2, 0, 0), entry(1, 5, 0), entry(1, 4, 0), entry(1, 3, 9)]

    result = Truffle::Changelog.new_entries(entries, "1.4.0")

    assert_equal([[2, 0, 0], [1, 5, 0]], result.map { |e| [e.major, e.minor, e.patch] })
  end

  def test_new_entries_treats_a_missing_component_as_zero
    # "1.4" parses as the 1.4.0 baseline, so 1.4.0 is not newer but 1.4.1 is.
    entries = [entry(1, 4, 1), entry(1, 4, 0)]

    result = Truffle::Changelog.new_entries(entries, "1.4")

    assert_equal([[1, 4, 1]], result.map { |e| [e.major, e.minor, e.patch] })
  end
end
