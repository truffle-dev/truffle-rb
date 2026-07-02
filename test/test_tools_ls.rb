# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

# The ls built-in tool, a native port of pi's ls.ts execute path. Entries are
# listed one per line, sorted case-insensitively, with a "/" suffix on
# directories and dotfiles included. Files live in a temp dir so the suite stays
# hermetic. These exercise the model-visible contract: the schema, the sorted
# output, the directory suffix, dotfile inclusion, the entry limit with its
# notice, byte truncation, and the empty/missing/not-a-directory cases.
class TestToolsLs < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("truffle-ls")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def ls_tool
    Truffle::Tools.ls(cwd: @dir)
  end

  def touch(rel)
    full = File.join(@dir, rel)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, "x")
  end

  def ls(**opts)
    args = {}
    args["path"] = opts[:path] if opts.key?(:path)
    args["limit"] = opts[:limit] if opts.key?(:limit)
    ls_tool.call(args)
  end

  def test_schema_advertises_optional_path_and_limit
    schema = ls_tool.to_schema

    assert_equal "ls", schema[:name]
    assert_empty schema[:parameters][:required]
    props = schema[:parameters][:properties]

    assert_equal "string", props["path"][:type]
    assert_equal "number", props["limit"][:type]
  end

  def test_no_path_lists_the_bound_working_directory
    touch("only.txt")

    assert_equal "only.txt", ls
  end

  def test_entries_are_sorted_case_insensitively
    # Without a case fold, ASCII order would put the capitals first ("Banana",
    # "Cherry", "apple"); the fold interleaves them alphabetically.
    touch("Banana")
    touch("apple")
    touch("Cherry")

    assert_equal "apple\nBanana\nCherry", ls
  end

  def test_directories_get_a_trailing_slash
    touch("bfile")
    FileUtils.mkdir(File.join(@dir, "adir"))

    assert_equal "adir/\nbfile", ls
  end

  def test_dotfiles_are_included
    touch(".env")
    touch("visible.txt")

    assert_equal ".env\nvisible.txt", ls
  end

  def test_path_argument_lists_a_subdirectory
    touch("top.txt")
    touch("sub/inner.txt")

    assert_equal "inner.txt", ls(path: "sub")
  end

  def test_absolute_path_is_accepted
    touch("only.rb")

    assert_equal "only.rb", ls(path: @dir)
  end

  def test_empty_directory_reports_empty
    assert_equal "(empty directory)", ls
  end

  def test_missing_path_is_rejected
    error = assert_raises(RuntimeError) { ls(path: "nope") }

    assert_equal "Path not found: #{File.join(@dir, "nope")}", error.message
  end

  def test_file_path_is_rejected_as_not_a_directory
    touch("a.txt")
    target = File.join(@dir, "a.txt")

    error = assert_raises(RuntimeError) { ls(path: "a.txt") }

    assert_equal "Not a directory: #{target}", error.message
  end

  def test_entry_limit_caps_output_and_appends_notice
    touch("1.log")
    touch("2.log")
    touch("3.log")

    out = ls(limit: 2)

    assert_equal "1.log\n2.log\n\n[2 entries limit reached. Use limit=4 for more]", out
  end

  def test_under_the_limit_appends_no_notice
    # Boundary guard for the >= entry-limit check: three entries under a limit of
    # five must not trip the notice.
    touch("1.log")
    touch("2.log")
    touch("3.log")

    assert_equal "1.log\n2.log\n3.log", ls(limit: 5)
  end

  def test_zero_limit_yields_an_empty_listing
    # pi passes the limit through without a floor, so limit=0 breaks on the first
    # entry, leaves the results empty, and the empty-directory check wins before
    # any notice is built. This pins the no-clamp behavior (find, by contrast,
    # clamps its limit to one).
    touch("1.log")
    touch("2.log")

    assert_equal "(empty directory)", ls(limit: 0)
  end

  def test_byte_ceiling_truncates_and_appends_notice
    # Entry count is bounded by the limit, so only bytes can truncate here. 230
    # entries of 230 chars each is ~53KB of joined output, past the 50KB ceiling,
    # and stays under the 500 default entry limit so only the byte notice fires.
    230.times { |i| touch(format("a%0229d", i)) }

    out = ls

    assert out.end_with?("\n\n[50.0KB limit reached]"),
           "expected a byte-limit notice, got: #{out[-80..]}"
    refute_includes out, "entries limit reached"
  end
end
