# frozen_string_literal: true

module Truffle
  # Message-list transforms applied before a provider serializes a turn to its
  # API. Ported from pi's transform-messages.ts. Only the image-downgrade pass is
  # here: when the target model has no image input modality, image blocks in user
  # and tool-result messages are replaced with a placeholder text block, since a
  # non-vision model's API rejects image content. The rest of pi's
  # transformMessages (cross-model thinking handling, tool-call-id normalization,
  # synthetic tool results) depends on assistant-message provider/model metadata
  # our flat Message does not carry, and is left for a later slice.
  module MessageTransform
    module_function

    NON_VISION_USER_IMAGE_PLACEHOLDER = "(image omitted: model does not support images)"
    NON_VISION_TOOL_IMAGE_PLACEHOLDER = "(tool image omitted: model does not support images)"

    # Return messages unchanged for a vision model; otherwise rebuild user and
    # tool-result messages with their images replaced by the matching placeholder.
    # Assistant and system messages pass through untouched, matching pi.
    def downgrade_unsupported_images(messages, model)
      return messages if model.vision?

      messages.map do |message|
        case message.role
        when :user
          rebuild(message,
                  replace_images_with_placeholder(message.content,
                                                  NON_VISION_USER_IMAGE_PLACEHOLDER))
        when :tool
          rebuild(message,
                  replace_images_with_placeholder(message.content,
                                                  NON_VISION_TOOL_IMAGE_PLACEHOLDER))
        else
          message
        end
      end
    end

    # Walk a content list, dropping image blocks in favor of one placeholder text
    # block. Consecutive images collapse to a single placeholder: an image right
    # after a placeholder adds nothing, and a text block that already equals the
    # placeholder counts as one too. Non-image blocks pass through in order.
    def replace_images_with_placeholder(content, placeholder)
      result = []
      previous_was_placeholder = false

      content.each do |block|
        if block.type == :image
          result << Content::Text.new(text: placeholder) unless previous_was_placeholder
          previous_was_placeholder = true
          next
        end

        result << block
        previous_was_placeholder = block.respond_to?(:text) && block.text == placeholder
      end

      result
    end

    # Rebuild a message with new content, preserving the fields the image pass
    # does not touch (role, tool-call id, tool name).
    def rebuild(message, content)
      Message.new(role: message.role, content: content, tool_call_id: message.tool_call_id,
                  name: message.name)
    end
  end
end
