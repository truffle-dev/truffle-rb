# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

# The find built-in tool, a native port of pi's find.ts execute path. pi shells
# out to the fd binary so it can honor .gitignore; that pulls an external Rust
# tool, so this port matches the filesystem with Dir.glob and mirrors pi's
# pluggable FindOperations.glob branch (.git and node_modules excluded, hidden
# files included). Files live in a temp dir so the suite stays hermetic. These
# exercise the model-visible contract: the schema, the relativized posix output,
# the exclusions, the result limit with its notice, and the empty/missing cases.
class TestToolsFind < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("truffle-find")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def find_tool
    Truffle::Tools.find(cwd: @dir)
  end

  def touch(rel)
    full = File.join(@dir, rel)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, "x")
  end

  def find(pattern, **opts)
    args = { "pattern" => pattern }
    args["path"] = opts[:path] if opts.key?(:path)
    args["limit"] = opts[:limit] if opts.key?(:limit)
    find_tool.call(args)
  end

  def test_schema_advertises_pattern_required_path_and_limit_optional
    schema = find_tool.to_schema

    assert_equal "find", schema[:name]
    assert_equal %w[pattern], schema[:parameters][:required]
    props = schema[:parameters][:properties]

    assert_equal "string", props["pattern"][:type]
    assert_equal "string", props["path"][:type]
    assert_equal "number", props["limit"][:type]
  end

  def test_bare_pattern_matches_at_any_depth
    # pi prepends "**/" so a basename pattern recurses; the nested file lands.
    touch("a.rb")
    touch("sub/b.rb")
    touch("c.txt")

    assert_equal "a.rb\nsub/b.rb", find("*.rb")
  end

  def test_path_containing_pattern_is_anchored_at_any_depth
    touch("src/x.spec.ts")
    touch("src/deep/y.spec.ts")
    touch("other/z.spec.ts")

    assert_equal "src/deep/y.spec.ts\nsrc/x.spec.ts", find("src/**/*.spec.ts")
  end

  def test_node_modules_is_excluded
    touch("keep.js")
    touch("node_modules/pkg/index.js")

    assert_equal "keep.js", find("*.js")
  end

  def test_git_directory_is_excluded
    touch("keep.txt")
    touch(".git/config.txt")

    assert_equal "keep.txt", find("*.txt")
  end

  def test_hidden_files_are_included
    touch(".env")
    touch("visible.txt")

    assert_equal ".env", find(".env")
  end

  def test_extglob_braces_match_either_extension
    touch("a.rb")
    touch("b.txt")
    touch("c.md")

    assert_equal "a.rb\nb.txt", find("*.{rb,txt}")
  end

  def test_path_argument_scopes_the_search
    touch("top.rb")
    touch("sub/inner.rb")

    assert_equal "inner.rb", find("*.rb", path: "sub")
  end

  def test_no_match_reports_empty
    touch("a.rb")

    assert_equal "No files found matching pattern", find("*.py")
  end

  def test_missing_path_is_rejected
    error = assert_raises(RuntimeError) { find("*.rb", path: "nope") }

    assert_equal "Path not found: #{File.join(@dir, "nope")}", error.message
  end

  def test_result_limit_caps_output_and_appends_notice
    touch("1.log")
    touch("2.log")
    touch("3.log")

    out = find("*.log", limit: 2)

    assert_equal "1.log\n2.log\n\n[2 results limit reached. " \
                 "Use limit=4 for more, or refine pattern]", out
  end

  def test_under_the_limit_appends_no_notice
    # Boundary guard for the >= result-limit check: three matches under a limit
    # of five must not trip the notice.
    touch("1.log")
    touch("2.log")
    touch("3.log")

    assert_equal "1.log\n2.log\n3.log", find("*.log", limit: 5)
  end

  def test_non_positive_limit_clamps_to_one
    touch("1.log")
    touch("2.log")

    assert_equal "1.log\n\n[1 results limit reached. " \
                 "Use limit=2 for more, or refine pattern]", find("*.log", limit: 0)
    assert_equal "1.log\n\n[1 results limit reached. " \
                 "Use limit=2 for more, or refine pattern]", find("*.log", limit: -10)
  end

  def test_absolute_path_is_accepted
    touch("only.rb")

    assert_equal "only.rb", find("*.rb", path: @dir)
  end
end
