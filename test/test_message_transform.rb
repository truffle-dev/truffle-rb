# frozen_string_literal: true

require_relative "test_helper"

# Covers Truffle::MessageTransform.downgrade_unsupported_images, the image
# downgrade pass ported from pi's transform-messages.ts.
class TestMessageTransform < Minitest::Test
  USER_PLACEHOLDER = Truffle::MessageTransform::NON_VISION_USER_IMAGE_PLACEHOLDER
  TOOL_PLACEHOLDER = Truffle::MessageTransform::NON_VISION_TOOL_IMAGE_PLACEHOLDER

  def test_placeholder_strings_match_pi
    assert_equal "(image omitted: model does not support images)", USER_PLACEHOLDER
    assert_equal "(tool image omitted: model does not support images)", TOOL_PLACEHOLDER
  end

  def test_vision_model_returns_the_same_array_untouched
    messages = [Truffle::Message.user([text("hi"), image])]
    result = Truffle::MessageTransform.downgrade_unsupported_images(messages,
                                                                    model(input: %i[text image]))

    assert_same messages, result
  end

  def test_non_vision_replaces_a_user_image_with_the_placeholder
    messages = [Truffle::Message.user([image])]
    result = Truffle::MessageTransform.downgrade_unsupported_images(messages,
                                                                    model(input: %i[text]))

    assert_equal [Truffle::Content::Text.new(text: USER_PLACEHOLDER)], result.first.content
  end

  def test_non_vision_keeps_surrounding_text_in_order
    messages = [Truffle::Message.user([text("before"), image, text("after")])]
    result = Truffle::MessageTransform.downgrade_unsupported_images(messages,
                                                                    model(input: %i[text]))

    assert_equal %w[before] + [USER_PLACEHOLDER] + %w[after], result.first.content.map(&:text)
  end

  def test_non_vision_collapses_consecutive_images_to_one_placeholder
    messages = [Truffle::Message.user([image, image, image])]
    result = Truffle::MessageTransform.downgrade_unsupported_images(messages,
                                                                    model(input: %i[text]))

    assert_equal [USER_PLACEHOLDER], result.first.content.map(&:text)
  end

  def test_non_vision_image_after_an_existing_placeholder_text_adds_nothing
    messages = [Truffle::Message.user([text(USER_PLACEHOLDER), image])]
    result = Truffle::MessageTransform.downgrade_unsupported_images(messages,
                                                                    model(input: %i[text]))

    assert_equal [USER_PLACEHOLDER], result.first.content.map(&:text)
  end

  def test_non_vision_uses_the_tool_placeholder_and_keeps_tool_fields
    messages = [Truffle::Message.tool(content: [image], tool_call_id: "call_1", name: "read")]
    result = Truffle::MessageTransform.downgrade_unsupported_images(messages,
                                                                    model(input: %i[text]))

    downgraded = result.first

    assert_equal [Truffle::Content::Text.new(text: TOOL_PLACEHOLDER)], downgraded.content
    assert_equal "call_1", downgraded.tool_call_id
    assert_equal "read", downgraded.name
  end

  def test_non_vision_leaves_assistant_and_system_messages_as_the_same_object
    assistant = Truffle::Message.assistant(content: text("answer"))
    system = Truffle::Message.system("rules")
    result = Truffle::MessageTransform.downgrade_unsupported_images([assistant, system],
                                                                    model(input: %i[text]))

    assert_same assistant, result[0]
    assert_same system, result[1]
  end

  def test_non_vision_user_without_images_keeps_its_text
    messages = [Truffle::Message.user([text("just text")])]
    result = Truffle::MessageTransform.downgrade_unsupported_images(messages,
                                                                    model(input: %i[text]))

    assert_equal ["just text"], result.first.content.map(&:text)
  end

  private

  def text(str)
    Truffle::Content::Text.new(text: str)
  end

  def image
    Truffle::Content::Image.new(data: "Zm9v", mime_type: "image/png")
  end

  def model(input:)
    Truffle::Model.new(
      id: "m", name: "M", provider: "p", api: :messages,
      context_window: 100_000, max_output: 4096, input: input,
      cost: { input: 1.0, output: 1.0, cache_read: 0.0, cache_write: 0.0 }
    )
  end
end
