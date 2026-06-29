# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

# .gitignore respect for the find tool. pi gets this for free from the fd
# binary (the Rust `ignore` crate); since this port matches the tree natively,
# the rules are evaluated by Truffle::Tools::Gitignore per gitignore(5). These
# exercise the behavior through the model-visible find contract: a hermetic temp
# tree with .gitignore files, asserting which paths survive. The temp dir has no
# .git, so the matcher's boundary falls back to the search root, which keeps the
# cases self-contained. They cover the semantics fd would apply: simple ignore,
# negation re-include, anchored vs floating, directory-only rules, nested
# precedence, the prune rule, the "**" forms, comments, and trailing spaces.
class TestToolsGitignore < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("truffle-gitignore")
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

  def gitignore(rel, body)
    touch(rel)
    File.write(File.join(@dir, rel), body)
  end

  def find(pattern)
    find_tool.call("pattern" => pattern)
  end

  def test_simple_pattern_is_ignored
    gitignore(".gitignore", "*.log\n")
    touch("build.log")
    touch("app.rb")

    assert_equal "No files found matching pattern", find("*.log")
    assert_equal "app.rb", find("*.rb")
  end

  def test_negation_re_includes_after_a_broad_ignore
    # Last-match-wins: "*.log" ignores both, then "!important.log" re-includes.
    gitignore(".gitignore", "*.log\n!important.log\n")
    touch("a.log")
    touch("important.log")

    assert_equal "important.log", find("*.log")
  end

  def test_anchored_pattern_only_matches_the_gitignore_directory
    # A leading slash roots the pattern at the .gitignore's directory, so a
    # same-named file nested deeper is not ignored.
    gitignore(".gitignore", "/root.txt\n")
    touch("root.txt")
    touch("sub/root.txt")

    assert_equal "sub/root.txt", find("**/root.txt")
  end

  def test_floating_pattern_matches_at_any_depth
    # No slash means the pattern floats and matches at every level.
    gitignore(".gitignore", "secret.txt\n")
    touch("secret.txt")
    touch("sub/secret.txt")

    assert_equal "No files found matching pattern", find("**/secret.txt")
  end

  def test_directory_only_rule_prunes_the_directory_not_a_same_named_file
    # A trailing slash restricts the rule to directories: the build/ tree is
    # pruned, but a file named build elsewhere survives.
    gitignore(".gitignore", "build/\n")
    touch("build/out.o")
    touch("app/build")

    assert_equal "No files found matching pattern", find("**/*.o")
    assert_equal "app/build", find("**/build")
  end

  def test_nested_gitignore_overrides_a_shallower_rule
    # A deeper .gitignore wins: root ignores *.txt, sub re-includes keep.txt.
    gitignore(".gitignore", "*.txt\n")
    gitignore("sub/.gitignore", "!keep.txt\n")
    touch("top.txt")
    touch("sub/keep.txt")
    touch("sub/other.txt")

    assert_equal "sub/keep.txt", find("**/*.txt")
  end

  def test_prune_rule_blocks_re_include_under_an_ignored_directory
    # gitignore(5): a file cannot be re-included while its parent directory
    # stays excluded, so the negation here is inert.
    gitignore(".gitignore", "logs/\n!logs/important.log\n")
    touch("logs/important.log")
    touch("logs/other.log")

    assert_equal "No files found matching pattern", find("**/*.log")
  end

  def test_trailing_double_star_ignores_everything_inside
    gitignore(".gitignore", "cache/**\n")
    touch("cache/a/b.o")
    touch("keep.o")

    assert_equal "keep.o", find("**/*.o")
  end

  def test_comments_and_blank_lines_are_skipped
    gitignore(".gitignore", "# a comment\n\n*.bak\n")
    touch("x.bak")
    touch("y.rb")

    assert_equal "No files found matching pattern", find("*.bak")
    assert_equal "y.rb", find("*.rb")
  end

  def test_trailing_spaces_are_stripped_from_a_pattern
    gitignore(".gitignore", "*.tmp   \n")
    touch("a.tmp")

    assert_equal "No files found matching pattern", find("*.tmp")
  end
end
