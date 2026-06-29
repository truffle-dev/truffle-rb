# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

# The edit built-in tool, ported from pi's edit.ts plus the matching core in
# edit-diff.ts. Files live in a temp dir so the suite stays hermetic. The
# diff/patch rendering pi feeds to its TUI is out of scope, so these exercise the
# model-visible contract: the success string, the verbatim error messages, and
# the bytes left on disk (line-ending and BOM preservation, fuzzy matching).
class TestToolsEdit < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("truffle-edit")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def edit_tool
    Truffle::Tools.edit(cwd: @dir)
  end

  def write_file(name, body)
    File.write(File.join(@dir, name), body)
  end

  def read_back(name)
    File.read(File.join(@dir, name))
  end

  def edit(name, *pairs)
    edits = pairs.map { |old, new| { "oldText" => old, "newText" => new } }
    edit_tool.call("path" => name, "edits" => edits)
  end

  def test_schema_advertises_path_and_edits_required
    schema = edit_tool.to_schema

    assert_equal "edit", schema[:name]
    assert_equal %w[path edits], schema[:parameters][:required]
    props = schema[:parameters][:properties]

    assert_equal "string", props["path"][:type]
    assert_equal "array", props["edits"][:type]
    item = props["edits"][:items]

    assert_equal %w[oldText newText], item[:required]
    refute item[:additionalProperties]
    assert_equal "string", item[:properties]["oldText"][:type]
    assert_equal "string", item[:properties]["newText"][:type]
  end

  def test_single_exact_replacement
    write_file("a.txt", "hello world\n")

    out = edit("a.txt", %w[world ruby])

    assert_equal "hello ruby\n", read_back("a.txt")
    assert_equal "Successfully replaced 1 block(s) in a.txt.", out
  end

  def test_multiple_disjoint_edits_in_one_call
    write_file("b.txt", "one two three\n")

    out = edit("b.txt", %w[one 1], %w[three 3])

    assert_equal "1 two 3\n", read_back("b.txt")
    assert_equal "Successfully replaced 2 block(s) in b.txt.", out
  end

  def test_edits_apply_against_original_not_incrementally
    # The second edit's oldText is matched against the original file, so a first
    # edit that would create that text must not change which region matches.
    write_file("c.txt", "alpha\nbeta\n")

    edit("c.txt", %w[alpha beta], %w[beta gamma])

    assert_equal "beta\ngamma\n", read_back("c.txt")
  end

  def test_missing_file_reports_enoent
    error = assert_raises(RuntimeError) { edit("nope.txt", %w[a b]) }

    assert_equal "Could not edit file: nope.txt. Error code: ENOENT.", error.message
  end

  def test_empty_edits_array_is_rejected
    write_file("d.txt", "body")

    error = assert_raises(RuntimeError) { edit_tool.call("path" => "d.txt", "edits" => []) }

    assert_equal "Edit tool input is invalid. edits must contain at least one replacement.",
                 error.message
  end

  def test_old_text_not_found_single_edit
    write_file("e.txt", "the quick brown fox\n")

    error = assert_raises(RuntimeError) { edit("e.txt", %w[missing here]) }

    assert_equal "Could not find the exact text in e.txt. " \
                 "The old text must match exactly including all whitespace and newlines.",
                 error.message
  end

  def test_old_text_not_found_multi_edit_names_index
    write_file("f.txt", "the quick brown fox\n")

    error = assert_raises(RuntimeError) do
      edit("f.txt", %w[quick slow], %w[missing here])
    end

    assert_equal "Could not find edits[1] in f.txt. " \
                 "The oldText must match exactly including all whitespace and newlines.",
                 error.message
  end

  def test_non_unique_old_text_single_edit
    write_file("g.txt", "ab ab ab\n")

    error = assert_raises(RuntimeError) { edit("g.txt", %w[ab XX]) }

    assert_equal "Found 3 occurrences of the text in g.txt. " \
                 "The text must be unique. Please provide more context to make it unique.",
                 error.message
  end

  def test_non_unique_old_text_multi_edit_names_index
    write_file("h.txt", "ab ab\nzz\n")

    error = assert_raises(RuntimeError) do
      edit("h.txt", %w[zz YY], %w[ab XX])
    end

    assert_equal "Found 2 occurrences of edits[1] in h.txt. " \
                 "Each oldText must be unique. Please provide more context to make it unique.",
                 error.message
  end

  def test_adjacent_disjoint_edits_are_allowed
    # Two edits that touch end to end with no gap are not overlapping: the first
    # ends exactly where the second begins. The boundary is exclusive (>), so
    # both must land.
    write_file("adj.txt", "abcdef\n")

    out = edit("adj.txt", %w[abc XY], %w[def ZW])

    assert_equal "XYZW\n", read_back("adj.txt")
    assert_equal "Successfully replaced 2 block(s) in adj.txt.", out
  end

  def test_overlapping_edits_are_rejected
    write_file("i.txt", "abcdef\n")

    error = assert_raises(RuntimeError) do
      edit("i.txt", %w[abcd WX], %w[cdef YZ])
    end

    assert_equal "edits[0] and edits[1] overlap in i.txt. " \
                 "Merge them into one edit or target disjoint regions.", error.message
  end

  def test_empty_old_text_single_edit
    write_file("j.txt", "body\n")

    error = assert_raises(RuntimeError) { edit("j.txt", ["", "x"]) }

    assert_equal "oldText must not be empty in j.txt.", error.message
  end

  def test_empty_old_text_multi_edit_names_index
    write_file("k.txt", "body\n")

    error = assert_raises(RuntimeError) do
      edit("k.txt", %w[body BODY], ["", "x"])
    end

    assert_equal "edits[1].oldText must not be empty in k.txt.", error.message
  end

  def test_no_change_when_replacement_is_identical
    write_file("l.txt", "same\n")

    error = assert_raises(RuntimeError) { edit("l.txt", %w[same same]) }

    assert_equal "No changes made to l.txt. The replacement produced identical content. " \
                 "This might indicate an issue with special characters or the text not " \
                 "existing as expected.",
                 error.message
  end

  def test_crlf_line_endings_are_preserved
    write_file("m.txt", "one\r\ntwo\r\nthree\r\n")

    edit("m.txt", %w[two TWO])

    assert_equal "one\r\nTWO\r\nthree\r\n", read_back("m.txt")
  end

  def test_bom_is_preserved
    write_file("n.txt", "\uFEFFhello world\n")

    edit("n.txt", %w[world ruby])

    assert_equal "\uFEFFhello ruby\n", read_back("n.txt")
  end

  def test_fuzzy_match_folds_smart_quotes_and_dashes
    # The file holds curly quotes and an em dash; the model sends ASCII. Fuzzy
    # normalization folds both sides, so the match lands and the original bytes
    # of every other line are preserved.
    write_file("o.txt", "say \u201Chello\u201D \u2014 now\nkeep me\n")

    edit("o.txt", ["say \"hello\" - now", "done"])

    assert_equal "done\nkeep me\n", read_back("o.txt")
  end

  def test_fuzzy_match_ignores_trailing_whitespace
    # The file line has trailing spaces; the model's oldText does not. Fuzzy
    # normalization strips trailing whitespace per line on both sides.
    write_file("p.txt", "value   \nother\n")

    edit("p.txt", %w[value RESULT])

    assert_equal "RESULT   \nother\n", read_back("p.txt")
  end

  def test_edits_as_json_string_are_parsed
    # Some models send the edits array as a JSON string instead of a real array.
    write_file("q.txt", "hello\n")

    out = edit_tool.call("path" => "q.txt", "edits" => '[{"oldText":"hello","newText":"hi"}]')

    assert_equal "hi\n", read_back("q.txt")
    assert_equal "Successfully replaced 1 block(s) in q.txt.", out
  end

  def test_legacy_top_level_old_new_text_is_folded
    # An older single-edit shape sends oldText/newText at the top level instead
    # of an edits array; pi folds the pair onto the list.
    write_file("r.txt", "hello\n")

    out = edit_tool.call("path" => "r.txt", "oldText" => "hello", "newText" => "hey")

    assert_equal "hey\n", read_back("r.txt")
    assert_equal "Successfully replaced 1 block(s) in r.txt.", out
  end

  def test_multi_edit_reverse_order_application
    # Two edits at different offsets must both land; applying back to front keeps
    # the earlier offset valid after the later region changes length.
    write_file("s.txt", "AAA mid BBB\n")

    edit("s.txt", %w[AAA start], %w[BBB end-of-line])

    assert_equal "start mid end-of-line\n", read_back("s.txt")
  end

  def test_absolute_path_is_accepted
    target = File.join(@dir, "abs.txt")
    File.write(target, "old\n")

    out = edit(target, %w[old new])

    assert_equal "new\n", File.read(target)
    assert_equal "Successfully replaced 1 block(s) in #{target}.", out
  end
end
