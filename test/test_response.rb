# frozen_string_literal: true

require_relative "test_helper"
require "json"

# Covers Response helpers that operate on the final assistant turn.
class TestResponse < Minitest::Test
  def test_parsed_returns_the_json_value_from_text
    response = response_with_text(%({"name":"Dana","tags":["vip","late-order"]}))

    assert_equal(
      { "name" => "Dana", "tags" => %w[vip late-order] },
      response.parsed
    )
  end

  def test_parsed_is_memoized
    response = response_with_text(%({"ok":true}))

    parsed = response.parsed

    assert_same parsed, response.parsed
  end

  def test_parsed_supports_json_null
    response = response_with_text("null")

    assert_nil response.parsed
  end

  def test_parsed_raises_for_invalid_json_without_changing_text
    response = response_with_text("not json")

    assert_raises(JSON::ParserError) { response.parsed }
    assert_equal "not json", response.text
  end

  private

  def response_with_text(text)
    Truffle::Response.new(message: Truffle::Message.assistant(content: text))
  end
end
