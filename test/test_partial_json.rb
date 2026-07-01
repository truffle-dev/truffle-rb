# frozen_string_literal: true

require "test_helper"

# Reference outputs were captured from the partial-json package (0.1.7), the
# library pi depends on. A differential harness compared this port against that
# package across ~600 inputs (hand-picked, every prefix of complete documents,
# and several Allow masks); the representative cases below are baked in so CI
# proves the port offline.
class TestPartialJson < Minitest::Test
  include Truffle

  def test_parses_complete_documents_like_json
    assert_equal({ "key" => "value" }, PartialJson.parse('{"key":"value"}'))
    assert_equal([1, 2, 3], PartialJson.parse("[1,2,3]"))
    assert_equal("hello", PartialJson.parse('"hello"'))
    assert_equal(123, PartialJson.parse("123"))
    assert_in_delta(-4.5, PartialJson.parse("-4.5"))
    assert_nil(PartialJson.parse("null"))
    assert(PartialJson.parse("true"))
    refute(PartialJson.parse("false"))
    assert_equal({ "a" => { "b" => [1, 2] } }, PartialJson.parse('{"a":{"b":[1,2]}}'))
  end

  def test_returns_completed_values_before_the_closing_token
    assert_equal({ "key" => "value" }, PartialJson.parse('{"key": "value"'))
    assert_equal({ "a" => 1 }, PartialJson.parse('{"a": 1, "b":'))
    assert_equal({ "a" => 1 }, PartialJson.parse('{"a": 1,'))
    assert_equal([1, 2], PartialJson.parse("[1, 2,"))
    assert_equal([1, 2, 3], PartialJson.parse("[1, 2, 3"))
  end

  def test_returns_partial_strings_by_default
    assert_equal({ "key" => "v" }, PartialJson.parse('{"key": "v'))
    assert_equal(%w[complete incompl], PartialJson.parse('["complete", "incompl'))
    assert_equal("unterminated", PartialJson.parse('"unterminated'))
  end

  def test_empty_object_and_array
    assert_equal({}, PartialJson.parse("{"))
    assert_equal([], PartialJson.parse("["))
    assert_equal({}, PartialJson.parse('{"a"'))
    assert_equal({}, PartialJson.parse('{"a":'))
  end

  def test_handles_internal_whitespace
    assert_equal({ "a" => 1 }, PartialJson.parse('{ "a" : 1 }'))
    nested = PartialJson.parse("{\"x\":\n[1,\n{\"k\":\"v\"}]\n}")

    assert_equal({ "x" => [1, { "k" => "v" }] }, nested)
  end

  def test_special_literals
    assert_equal(Float::INFINITY, PartialJson.parse("Infinity"))
    assert_equal(-Float::INFINITY, PartialJson.parse("-Infinity"))
    assert_predicate(PartialJson.parse("NaN"), :nan?)
  end

  def test_partial_special_literals_when_allowed
    assert_nil(PartialJson.parse("nu", allow: PartialJson::NULL))
    assert(PartialJson.parse("tr", allow: PartialJson::BOOL))
    refute(PartialJson.parse("fa", allow: PartialJson::BOOL))
  end

  def test_allow_mask_disables_partial_types
    assert_equal({}, PartialJson.parse('{"key": "v', allow: ~PartialJson::STR))
    assert_equal({ "key" => "value" }, PartialJson.parse('{"key": "value"', allow: PartialJson::OBJ))
    assert_equal(["complete string"], PartialJson.parse('["complete string", "incompl', allow: ~PartialJson::STR))
  end

  def test_disallowing_object_partials_propagates
    assert_equal([{ "a" => 1, "b" => 2 }], PartialJson.parse('[{"a": 1, "b": 2}, {"a": 3,', allow: PartialJson::ARR))
  end

  def test_blank_input_raises_malformed
    assert_raises(PartialJson::MalformedError) { PartialJson.parse("") }
    assert_raises(PartialJson::MalformedError) { PartialJson.parse("   ") }
  end

  def test_lone_minus_is_malformed
    assert_raises(PartialJson::MalformedError) { PartialJson.parse("-") }
  end

  def test_unterminated_number_without_num_partial_raises
    both_off = ~PartialJson::NUM & ~PartialJson::ARR
    assert_raises(PartialJson::PartialError) { PartialJson.parse("[123", allow: both_off) }
  end

  def test_unterminated_number_drops_from_array_when_num_partial_disabled
    # NUM off but ARR on: the in-flight number is dropped, the array partial returns.
    assert_equal([], PartialJson.parse("[123", allow: ~PartialJson::NUM))
  end

  def test_parse_streaming_returns_empty_object_for_blank
    assert_equal({}, PartialJson.parse_streaming(nil))
    assert_equal({}, PartialJson.parse_streaming(""))
    assert_equal({}, PartialJson.parse_streaming("   "))
  end

  def test_parse_streaming_parses_complete_and_partial
    assert_equal({ "a" => 1 }, PartialJson.parse_streaming('{"a":1}'))
    assert_equal({ "a" => "b" }, PartialJson.parse_streaming('{"a":"b'))
    assert_equal({ "a" => 1 }, PartialJson.parse_streaming('{"a":1,"b":'))
    assert_equal([1, 2], PartialJson.parse_streaming("[1,2,"))
  end

  def test_parse_streaming_uses_the_repair_path
    # A trailing backslash is invalid JSON; parse_streaming repairs then parses.
    assert_equal({ "path" => "C:" }, PartialJson.parse_streaming('{"path":"C:\\'))
  end

  def test_parse_streaming_falls_back_to_empty_object
    assert_equal({}, PartialJson.parse_streaming("not json at all"))
  end
end
