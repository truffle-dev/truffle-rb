# frozen_string_literal: true

require_relative "test_helper"

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
    refute open.redacted?
    assert hidden.redacted?
    assert_equal({ type: :thinking, thinking: "reasoning", signature: "sig" }, open.to_h)
    assert_equal true, hidden.to_h[:redacted]
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
    assert msg.tool_calls?
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
end
