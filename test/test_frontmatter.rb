# frozen_string_literal: true

require "test_helper"

# Frontmatter parsing, a port of pi's parseFrontmatter / extractFrontmatter. The
# block is the YAML between a leading "---" line and the next "---"; everything
# after is the body. A file without an opening fence, or with an unclosed one,
# has no frontmatter and is all body.
class TestFrontmatter < Minitest::Test
  def test_parses_a_block_and_returns_the_trimmed_body
    raw = "---\nname: skill\ndescription: does a thing\n---\nBody text\n"
    front, body = Truffle::Frontmatter.parse(raw)

    assert_equal({ "name" => "skill", "description" => "does a thing" }, front)
    assert_equal "Body text", body
  end

  def test_a_file_without_an_opening_fence_is_all_body
    front, body = Truffle::Frontmatter.parse("no fence here\nmore text")

    assert_empty front
    assert_equal "no fence here\nmore text", body
  end

  def test_an_unclosed_block_is_treated_as_body_not_frontmatter
    front, body = Truffle::Frontmatter.parse("---\nname: skill\nstill going")

    assert_empty front
    assert_equal "---\nname: skill\nstill going", body
  end

  def test_an_empty_block_yields_an_empty_hash
    front, body = Truffle::Frontmatter.parse("---\n---\nbody")

    assert_empty front
    assert_equal "body", body
  end

  def test_carriage_returns_are_normalized_before_parsing
    front, body = Truffle::Frontmatter.parse("---\r\nname: skill\r\n---\r\nbody")

    assert_equal({ "name" => "skill" }, front)
    assert_equal "body", body
  end

  def test_typed_scalars_round_trip_through_yaml
    front, = Truffle::Frontmatter.parse("---\ndisable-model-invocation: true\ncount: 3\n---\n")

    assert front["disable-model-invocation"]
    assert_equal 3, front["count"]
  end

  def test_a_block_with_nothing_after_the_closing_fence_has_an_empty_body
    front, body = Truffle::Frontmatter.parse("---\nname: skill\n---")

    assert_equal({ "name" => "skill" }, front)
    assert_equal "", body
  end
end
