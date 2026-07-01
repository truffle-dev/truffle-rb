# frozen_string_literal: true

require_relative "test_helper"

# Covers Truffle::UnicodeSanitizer, the lone-surrogate stripper ported from pi's
# utils/sanitize-unicode.ts. Fixtures build lone surrogates with
# [codepoint].pack("U"), which yields the invalid three-byte WTF-8 sequence a
# provider serializer would choke on. The suite is offline: pure string in,
# pure string out.
class TestUnicodeSanitizer < Minitest::Test
  include Truffle

  LONE_HIGH = [0xD83D].pack("U") # unpaired high surrogate
  LONE_LOW  = [0xDC00].pack("U") # unpaired low surrogate

  def sanitize(text)
    UnicodeSanitizer.sanitize_surrogates(text)
  end

  def test_removes_a_lone_high_surrogate
    assert_equal "Text  here", sanitize("Text #{LONE_HIGH} here")
  end

  def test_removes_a_lone_low_surrogate
    assert_equal "AB", sanitize("A#{LONE_LOW}B")
  end

  def test_removes_an_adjacent_wtf8_surrogate_pair
    # In UTF-8 a valid astral char is one codepoint, so these adjacent surrogate
    # bytes can only be malformed input; both are stripped.
    assert_equal "[]", sanitize("[#{LONE_HIGH}#{LONE_LOW}]")
  end

  def test_preserves_a_valid_astral_emoji
    emoji = "Hello \u{1F648} World"
    result = sanitize(emoji)

    assert_equal emoji, result
    assert_predicate result, :valid_encoding?
  end

  def test_preserves_the_adjacent_valid_codepoint_below_the_surrogate_range
    # U+D7FF encodes as ED 9F BF, one below the surrogate lead-continuation
    # range, so it must survive untouched.
    valid = [0xD7FF].pack("U")
    fixture = "x#{valid}y"

    assert_equal fixture, sanitize(fixture)
  end

  def test_leaves_clean_ascii_untouched_and_returns_the_same_object
    clean = "hello world"

    assert_same clean, sanitize(clean)
  end

  def test_leaves_a_clean_unicode_string_frozen
    # Frozen by the frozen_string_literal magic comment at the top of the file.
    clean = "café \u{1F600}"

    result = sanitize(clean)

    assert_same clean, result
    assert_predicate result, :frozen?
  end

  def test_result_is_json_serializable
    require "json"
    sanitized = sanitize("Text #{LONE_HIGH} here")

    assert_equal({ "t" => "Text  here" }, JSON.parse(JSON.generate(t: sanitized)))
  end

  def test_returns_utf8_encoded_text
    result = sanitize("A#{LONE_LOW}B")

    assert_equal Encoding::UTF_8, result.encoding
    assert_predicate result, :valid_encoding?
  end
end
