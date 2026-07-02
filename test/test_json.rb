# frozen_string_literal: true

require "test_helper"
require "json"

class TestJson < Minitest::Test
  include Truffle

  def test_plain_json_is_unchanged
    input = %({"a": 1, "b": [2, 3]})

    assert_equal input, Json.strip_comments(input)
  end

  def test_strips_a_line_comment
    input = %({\n  "a": 1 // the answer\n})

    assert_equal %({\n  "a": 1 \n}), Json.strip_comments(input)
  end

  def test_strips_a_full_line_comment
    input = %(// header\n{"a": 1})

    assert_equal %(\n{"a": 1}), Json.strip_comments(input)
  end

  def test_keeps_a_double_slash_inside_a_string
    input = %({"url": "http://example.com//path"})

    assert_equal input, Json.strip_comments(input)
  end

  def test_keeps_an_escaped_quote_inside_a_string
    # The escaped quote does not end the string, so the // after it is still inside
    # the literal and is not a comment.
    input = %({"a": "b\\"c // still in string"})

    assert_equal input, Json.strip_comments(input)
  end

  def test_strips_a_trailing_comma_before_a_brace
    assert_equal %({"a": 1}), Json.strip_comments(%({"a": 1,}))
  end

  def test_strips_a_trailing_comma_before_a_bracket
    assert_equal %([1, 2]), Json.strip_comments(%([1, 2,]))
  end

  def test_strips_a_trailing_comma_with_whitespace_before_the_closer
    assert_equal %([1\n]), Json.strip_comments(%([1,\n]))
  end

  def test_keeps_a_separating_comma
    input = %({"a": 1, "b": 2})

    assert_equal input, Json.strip_comments(input)
  end

  def test_keeps_a_comma_closer_sequence_inside_a_string
    input = %({"a": "x,]"})

    assert_equal input, Json.strip_comments(input)
  end

  def test_strips_comments_and_trailing_commas_together
    input = %({\n  "a": 1, // first\n  "b": 2,\n})

    assert_equal %({\n  "a": 1, \n  "b": 2\n}), Json.strip_comments(input)
  end

  def test_result_round_trips_through_a_strict_parser
    jsonc = %({\n  // a comment\n  "name": "pi",\n  "tags": ["x", "y",],\n})

    assert_equal({ "name" => "pi", "tags" => %w[x y] }, JSON.parse(Json.strip_comments(jsonc)))
  end

  def test_empty_string
    assert_equal "", Json.strip_comments("")
  end
end
