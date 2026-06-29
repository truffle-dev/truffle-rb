# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

# The grep built-in tool, a native port of pi's grep.ts execute path. pi shells
# out to the rg binary for the search and .gitignore handling; that pulls an
# external Rust tool, so this port scans the tree with Ruby's Regexp and reuses
# Find (and through it Gitignore) for the file walk. Files live in a temp dir so
# the suite stays hermetic. These exercise the model-visible contract: the
# schema, the match/context line shapes, case and literal switches, the glob
# filter, .gitignore respect, binary skipping, the match limit and long-line
# notices, single-file basename output, and the empty/missing cases.
class TestToolsGrep < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("truffle-grep")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def grep_tool
    Truffle::Tools.grep(cwd: @dir)
  end

  def write(rel, content)
    full = File.join(@dir, rel)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end

  def grep(pattern, **opts)
    args = { "pattern" => pattern }
    %i[path glob context limit].each { |k| args[k.to_s] = opts[k] if opts.key?(k) }
    args["ignoreCase"] = opts[:ignore_case] if opts.key?(:ignore_case)
    args["literal"] = opts[:literal] if opts.key?(:literal)
    grep_tool.call(args)
  end

  def test_schema_advertises_pattern_required_and_the_optional_switches
    schema = grep_tool.to_schema

    assert_equal "grep", schema[:name]
    assert_equal %w[pattern], schema[:parameters][:required]
    props = schema[:parameters][:properties]

    assert_equal "string", props["pattern"][:type]
    assert_equal "string", props["path"][:type]
    assert_equal "string", props["glob"][:type]
    assert_equal "boolean", props["ignoreCase"][:type]
    assert_equal "boolean", props["literal"][:type]
    assert_equal "number", props["context"][:type]
    assert_equal "number", props["limit"][:type]
  end

  def test_match_line_carries_path_and_line_number
    write("a.rb", "hello\nworld\n")

    assert_equal "a.rb:2: world", grep("world")
  end

  def test_pattern_is_a_regular_expression
    write("a.txt", "foo123\nbar\n")

    assert_equal "a.txt:1: foo123", grep('\d+')
  end

  def test_matches_across_files_are_path_sorted
    write("a.txt", "match here")
    write("b.txt", "match too")

    assert_equal "a.txt:1: match here\nb.txt:1: match too", grep("match")
  end

  def test_ignore_case_switch
    write("a.txt", "Hello")

    assert_equal "No matches found", grep("hello")
    assert_equal "a.txt:1: Hello", grep("hello", ignore_case: true)
  end

  def test_literal_treats_the_pattern_verbatim
    write("dots.txt", "a.b")
    write("other.txt", "axb")

    # As a regex "a.b" matches both; literal restricts it to the real dot.
    assert_equal "dots.txt:1: a.b", grep("a.b", literal: true)
  end

  def test_context_window_brackets_the_match
    write("a.txt", "l1\nl2\nl3\nl4\nl5\n")

    assert_equal "a.txt-2- l2\na.txt:3: l3\na.txt-4- l4", grep("l3", context: 1)
  end

  def test_glob_filters_the_searched_files
    write("a.rb", "needle")
    write("b.txt", "needle")

    assert_equal "a.rb:1: needle", grep("needle", glob: "*.rb")
  end

  def test_gitignored_files_are_skipped
    write(".gitignore", "*.log\n")
    write("skip.log", "secret")
    write("keep.txt", "secret")

    assert_equal "keep.txt:1: secret", grep("secret")
  end

  def test_binary_files_are_skipped
    write("bin.dat", "\x00needle")
    write("text.txt", "needle")

    assert_equal "text.txt:1: needle", grep("needle")
  end

  def test_single_file_path_reports_a_basename
    write("sub/a.txt", "find me")

    assert_equal "a.txt:1: find me", grep("find", path: "sub/a.txt")
  end

  def test_no_matches_message
    write("a.txt", "nothing here")

    assert_equal "No matches found", grep("zzz")
  end

  def test_missing_path_raises
    error = assert_raises(RuntimeError) { grep("x", path: "nope") }

    assert_includes error.message, "Path not found"
  end

  def test_match_limit_caps_results_and_adds_a_notice
    write("a.txt", "x\nx\nx\n")

    expected = "a.txt:1: x\na.txt:2: x\n\n" \
               "[2 matches limit reached. Use limit=4 for more, or refine pattern]"

    assert_equal expected, grep("x", limit: 2)
  end

  def test_under_the_limit_has_no_notice
    write("a.txt", "x\nx\n")

    assert_equal "a.txt:1: x\na.txt:2: x", grep("x", limit: 5)
  end

  def test_long_lines_are_truncated_with_a_notice
    write("a.txt", "needle#{"a" * 600}")

    output = grep("needle")

    assert output.start_with?("a.txt:1: needle")
    assert_includes output, "... [truncated]"
    assert_includes output, "Some lines truncated to 500 chars. Use read tool to see full lines"
  end
end
