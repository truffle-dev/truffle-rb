# frozen_string_literal: true

require_relative "test_helper"
require "json"

# Covers the typed content blocks and the way Message normalizes a turn's
# content into a list of them.
class TestContent < Minitest::Test
  def test_text_block_to_h_and_equality
    a = Truffle::Content::Text.new(text: "hello")
    b = Truffle::Content::Text.new(text: "hello")

    assert_equal :text, a.type
    assert_equal({ type: :text, text: "hello" }, a.to_h)
    assert_equal a, b
    assert_equal a.hash, b.hash
  end

  def test_text_block_carries_signature_only_when_present
    plain = Truffle::Content::Text.new(text: "hi")
    signed = Truffle::Content::Text.new(text: "hi", signature: "msg_1")

    refute plain.to_h.key?(:signature)
    assert_equal "msg_1", signed.to_h[:signature]
    refute_equal plain, signed
  end

  def test_thinking_block_redacted_flag
    open = Truffle::Content::Thinking.new(thinking: "reasoning", signature: "sig")
    hidden = Truffle::Content::Thinking.new(thinking: "", signature: "sig", redacted: true)

    assert_equal :thinking, open.type
    refute_predicate open, :redacted?
    assert_predicate hidden, :redacted?
    assert_equal({ type: :thinking, thinking: "reasoning", signature: "sig" }, open.to_h)
    assert hidden.to_h[:redacted]
  end

  def test_image_block_to_h
    img = Truffle::Content::Image.new(data: "abc123", mime_type: "image/png")

    assert_equal :image, img.type
    assert_equal({ type: :image, data: "abc123", mime_type: "image/png" }, img.to_h)
  end

  def test_message_wraps_a_bare_string_as_one_text_block
    msg = Truffle::Message.user("what is the weather")

    assert_equal 1, msg.content.length
    assert_instance_of Truffle::Content::Text, msg.content.first
    assert_equal "what is the weather", msg.text
  end

  def test_message_with_no_content_has_empty_blocks_and_nil_text
    msg = Truffle::Message.assistant

    assert_empty msg.content
    assert_nil msg.text
  end

  def test_message_text_joins_multiple_text_blocks
    msg = Truffle::Message.new(
      role: :assistant,
      content: [
        Truffle::Content::Text.new(text: "one "),
        Truffle::Content::Text.new(text: "two")
      ]
    )

    assert_equal "one two", msg.text
  end

  def test_message_keeps_mixed_blocks_and_skips_non_text_in_text
    msg = Truffle::Message.user(
      [
        Truffle::Content::Text.new(text: "look at this"),
        Truffle::Content::Image.new(data: "zzz", mime_type: "image/jpeg")
      ]
    )

    assert_equal 2, msg.content.length
    assert_equal "look at this", msg.text
  end

  def test_tool_calls_are_content_blocks
    call = Truffle::ToolCall.new(id: "call_1", name: "add", arguments: { "a" => 1 })
    msg = Truffle::Message.assistant(content: "calling add", tool_calls: [call])

    assert_equal 2, msg.content.length
    assert_predicate msg, :tool_calls?
    assert_equal [call], msg.tool_calls
    assert_equal "calling add", msg.text
  end

  def test_tool_call_block_type_and_to_h
    call = Truffle::ToolCall.new(id: "call_2", name: "mul", arguments: { "a" => 2, "b" => 3 })

    assert_equal :tool_call, call.type
    assert_equal(
      { type: :tool_call, id: "call_2", name: "mul", arguments: { "a" => 2, "b" => 3 } },
      call.to_h
    )
  end

  def test_message_to_h_emits_content_as_block_hashes
    call = Truffle::ToolCall.new(id: "c", name: "t", arguments: {})
    msg = Truffle::Message.assistant(content: "hi", tool_calls: [call])

    h = msg.to_h

    assert_equal :assistant, h[:role]
    assert_equal(
      [{ type: :text, text: "hi" }, { type: :tool_call, id: "c", name: "t", arguments: {} }],
      h[:content]
    )
  end

  def test_content_from_h_round_trips_each_block_type
    [
      Truffle::Content::Text.new(text: "hi", signature: "msg_1"),
      Truffle::Content::Thinking.new(thinking: "reasoning", signature: "sig"),
      Truffle::Content::Thinking.new(thinking: "", signature: "sig", redacted: true),
      Truffle::Content::Image.new(data: "abc", mime_type: "image/png"),
      Truffle::ToolCall.new(id: "c1", name: "add", arguments: { "a" => 1 })
    ].each do |block|
      assert_equal block, Truffle::Content.from_h(block.to_h)
    end
  end

  def test_content_from_h_tolerates_string_keys_after_a_json_round_trip
    original = Truffle::Content::Text.new(text: "hi")
    string_keyed = JSON.parse(JSON.generate(original.to_h))

    assert_equal original, Truffle::Content.from_h(string_keyed)
  end

  def test_content_from_h_rejects_an_unknown_block_type
    assert_raises(ArgumentError) { Truffle::Content.from_h({ type: "mystery" }) }
  end

  def test_message_from_h_round_trips_a_turn_with_text_and_tool_call
    call = Truffle::ToolCall.new(id: "c", name: "t", arguments: { "x" => 1 })
    original = Truffle::Message.assistant(content: "calling", tool_calls: [call])

    restored = Truffle::Message.from_h(JSON.parse(JSON.generate(original.to_h)))

    assert_equal :assistant, restored.role
    assert_equal "calling", restored.text
    assert_equal "t", restored.tool_calls.first.name
    assert_equal({ "x" => 1 }, restored.tool_calls.first.arguments)
  end

  def test_message_from_h_round_trips_a_tool_result
    original = Truffle::Message.tool(content: "42", tool_call_id: "c", name: "add")

    restored = Truffle::Message.from_h(original.to_h)

    assert_equal :tool, restored.role
    assert_equal "c", restored.tool_call_id
    assert_equal "add", restored.name
    assert_equal "42", restored.text
  end
end
