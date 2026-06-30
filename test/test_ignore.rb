# frozen_string_literal: true

require "test_helper"

# Gitignore-style matching, a zero-dependency port of the `ignore` npm package pi
# layers over its skills directory walk. The cases below cover the pattern shapes
# a real ignore file uses: anchoring, segment vs cross-segment wildcards, the
# single-character "?", character classes, directory-only patterns, negation with
# last-match-wins, ancestor-directory exclusion, and the comment/blank/escape
# rules that decide which lines are patterns at all.
class TestIgnore < Minitest::Test
  def ig(*patterns)
    Truffle::Ignore.new.add(patterns)
  end

  def test_an_unanchored_name_matches_at_any_depth
    m = ig("node_modules")

    assert m.ignores?("node_modules")
    assert m.ignores?("src/node_modules")
    assert m.ignores?("node_modules/index.js")
    refute m.ignores?("my_node_modules")
    refute m.ignores?("src/node_modules_old")
  end

  def test_a_star_matches_within_a_single_segment
    m = ig("*.log")

    assert m.ignores?("app.log")
    assert m.ignores?("src/app.log")
    refute m.ignores?("app.txt")
  end

  def test_a_leading_slash_anchors_to_the_root
    m = ig("/build")

    assert m.ignores?("build")
    assert m.ignores?("build/app.js")
    refute m.ignores?("src/build")
  end

  def test_a_trailing_slash_matches_directories_only
    m = ig("dist/")

    assert m.ignores?("dist/")
    assert m.ignores?("dist/app.js")
    assert m.ignores?("src/dist/")
    refute m.ignores?("dist")
  end

  def test_a_leading_double_star_matches_at_any_depth
    m = ig("**/tmp")

    assert m.ignores?("tmp")
    assert m.ignores?("a/tmp")
    assert m.ignores?("a/b/tmp")
  end

  def test_an_embedded_double_star_spans_directories
    m = ig("a/**/b")

    assert m.ignores?("a/b")
    assert m.ignores?("a/x/b")
    assert m.ignores?("a/x/y/b")
    refute m.ignores?("x/a/b")
    refute m.ignores?("a/bc")
  end

  def test_a_trailing_double_star_matches_everything_below
    m = ig("logs/**")

    assert m.ignores?("logs/app.log")
    assert m.ignores?("logs/2026/app.log")
    refute m.ignores?("logs")
  end

  def test_a_question_mark_matches_one_non_slash_character
    m = ig("file?.txt")

    assert m.ignores?("file1.txt")
    refute m.ignores?("file12.txt")
    refute m.ignores?("file.txt")
  end

  def test_a_character_class_matches_one_listed_character
    m = ig("main.[oa]")

    assert m.ignores?("main.o")
    assert m.ignores?("main.a")
    refute m.ignores?("main.c")
  end

  def test_a_negation_re_includes_a_previously_ignored_path
    m = ig("*.log", "!keep.log")

    assert m.ignores?("app.log")
    refute m.ignores?("keep.log")
  end

  def test_an_excluded_directory_cannot_be_re_included
    m = ig("build/", "!build/keep.js")

    assert m.ignores?("build/keep.js")
  end

  def test_an_ancestor_directory_match_ignores_its_children
    m = ig("build/")

    assert m.ignores?("build/nested/app.js")
  end

  def test_comments_and_blank_lines_are_not_patterns
    m = ig("# a comment", "", "   ", "real")

    assert m.ignores?("real")
    refute m.ignores?("# a comment")
  end

  def test_a_line_with_a_lone_trailing_backslash_is_dropped
    m = Truffle::Ignore.new.add("bad\\\ngood")

    assert m.ignores?("good")
    refute m.ignores?("bad")
  end

  def test_matching_is_case_insensitive
    m = ig("readme")

    assert m.ignores?("README")
  end

  def test_an_escaped_leading_hash_matches_a_literal_hash
    m = ig("\\#notes")

    assert m.ignores?("#notes")
  end

  def test_add_accepts_a_newline_string_and_returns_self
    m = Truffle::Ignore.new
    result = m.add("*.tmp\n*.bak")

    assert_same m, result
    assert m.ignores?("a.tmp")
    assert m.ignores?("a.bak")
  end

  def test_an_empty_or_nil_path_is_never_ignored
    m = ig("*")

    refute m.ignores?("")
    refute m.ignores?(nil)
  end
end
