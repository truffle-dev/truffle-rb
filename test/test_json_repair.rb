# frozen_string_literal: true

require_relative "test_helper"
require "json"

# Covers Truffle::JsonRepair, the malformed-JSON repairer ported from the
# dependency-free half of pi's utils/json-parse.ts. Fixtures embed raw control
# characters and invalid escapes the way a model sometimes emits tool-call
# arguments. The suite is offline: string in, repaired string or parsed value
# out.
class TestJsonRepair < Minitest::Test
  include Truffle

  def repair(json)
    JsonRepair.repair(json)
  end

  def parse(json)
    JsonRepair.parse(json)
  end

  def test_escapes_a_raw_newline_inside_a_string
    assert_equal '{"a":"line1\nline2"}', repair("{\"a\":\"line1\nline2\"}")
  end

  def test_escapes_a_raw_tab_inside_a_string
    assert_equal '{"a":"x\ty"}', repair("{\"a\":\"x\ty\"}")
  end

  def test_escapes_other_control_characters_as_unicode
    # U+0001 has no short form, so it becomes \u0001.
    assert_equal '{"a":"x\u0001y"}', repair("{\"a\":\"x\u0001y\"}")
  end

  def test_escapes_the_top_of_the_control_range
    # U+001F is the last control character; U+0020 (space) is not touched.
    assert_equal '{"a":"\u001f "}', repair("{\"a\":\"\u001f \"}")
  end

  def test_doubles_a_backslash_before_an_invalid_escape
    # A lone backslash before "p" is not a valid escape, so it is doubled.
    assert_equal '{"a":"c:\\\\path"}', repair('{"a":"c:\path"}')
  end

  def test_preserves_a_valid_short_escape
    valid = '{"a":"tab\there"}'

    assert_equal valid, repair(valid)
  end

  def test_preserves_a_valid_unicode_escape
    valid = '{"a":"\u00e9"}'

    assert_equal valid, repair(valid)
  end

  def test_leaves_control_characters_outside_strings_untouched
    # A raw newline between tokens is JSON whitespace, not string content, so
    # the in-string guard must leave it alone.
    structural = "{\n\"a\":1}"

    assert_equal structural, repair(structural)
  end

  def test_repair_does_not_alter_already_valid_json
    valid = '{"a":"plain","b":[1,2,3]}'

    assert_equal valid, repair(valid)
  end

  def test_parse_reads_valid_json_unchanged
    # repair is a no-op on well-formed JSON, so a valid document parses to the
    # same value it always did.
    assert_equal({ "a" => 1, "b" => [1, 2] }, parse('{"a":1,"b":[1,2]}'))
  end

  def test_parse_feeds_the_repaired_string_to_the_parser
    # The fix: repair runs on every input, so the parser only ever sees repaired
    # text and correctness does not depend on the installed json gem's strictness.
    # Under the strict bundled json this is the only visible difference from the
    # old try-parse-first code, which fed the raw input to the parser first.
    raw = '{"a":"c:\path"}'
    seen = nil
    JSON.stub(:parse, lambda { |arg, *|
      seen = arg
      { "ok" => true }
    }) do
      parse(raw)
    end

    assert_equal repair(raw), seen
    refute_equal raw, seen
  end

  def test_parse_repairs_a_raw_control_character
    parsed = parse("{\"a\":\"line1\nline2\"}")

    assert_equal({ "a" => "line1\nline2" }, parsed)
  end

  def test_parse_repairs_an_invalid_escape
    parsed = parse('{"a":"c:\path"}')

    assert_equal({ "a" => "c:\\path" }, parsed)
  end

  def test_parse_reraises_when_repair_changes_nothing
    # A structural error with no string-literal damage cannot be repaired, so
    # the original parse error surfaces rather than being swallowed.
    assert_raises(JSON::ParserError) { parse('{"x":}') }
  end
end
