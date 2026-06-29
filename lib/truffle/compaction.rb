# frozen_string_literal: true

require "json"

module Truffle
  # The decision layer for context compaction: how many context tokens a
  # conversation is using, and whether that has crossed the threshold where old
  # turns must be summarized to stay under the model's window.
  #
  # A faithful port of the trigger half of pi's compaction
  # (packages/agent/src/harness/compaction/compaction.ts): calculateContextTokens,
  # estimateTokens, estimateContextTokens, shouldCompact, and the settings. The
  # retention cut-point selection and the summarizer that calls the model are
  # separate slices; this one is pure and offline, so it can be checked exactly.
  module Compaction
    # Compaction thresholds and retention budget. reserve_tokens is held back for
    # the summary prompt and its output; keep_recent_tokens is the approximate
    # recent-context budget kept after a compaction. Mirrors pi's
    # CompactionSettings.
    Settings = Struct.new(:enabled, :reserve_tokens, :keep_recent_tokens, keyword_init: true)

    # pi's DEFAULT_COMPACTION_SETTINGS.
    DEFAULT_SETTINGS = Settings.new(
      enabled: true,
      reserve_tokens: 16_384,
      keep_recent_tokens: 20_000
    ).freeze

    # pi's ESTIMATED_IMAGE_CHARS: an image is charged a flat character budget,
    # since its real token cost is not in the text.
    ESTIMATED_IMAGE_CHARS = 4800

    module_function

    # The context tokens a provider usage block represents. pi prefers the
    # provider's own total when it reports one, falling back to the sum of the
    # token classes. In this port total_tokens is always that sum, so the
    # fallback only guards a usage built without it.
    def calculate_context_tokens(usage)
      total = usage.total_tokens
      return total if total.positive?

      usage.input + usage.output + usage.cache_read + usage.cache_write
    end

    # A conservative token estimate for one message: count the characters its
    # content blocks contribute, then four characters to a token (pi's heuristic).
    #
    # pi accounts per role (a user turn counts text and images, an assistant turn
    # counts text, thinking, and tool-call name plus arguments). Here content is a
    # uniform block list, so one walk gives the same result: a block type a role
    # never carries contributes nothing. The system prompt is the locked head, not
    # part of the conversation pi summarizes, so a system message estimates zero
    # (pi keeps the system prompt out of the message list entirely).
    def estimate_tokens(message)
      return 0 if message.role == :system

      chars = message.content.sum { |block| block_chars(block) }
      (chars / 4.0).ceil
    end

    # Estimate the context tokens for a conversation. With no usage, it is the
    # character estimate of every message (pi's no-usage branch). With a usage,
    # that usage is the measured context as of the last provider response and the
    # messages are the turns appended since, so the estimate is the measured total
    # plus the estimate of those trailing turns (pi's with-usage branch).
    def estimate_context_tokens(messages, usage: nil)
      trailing = messages.sum { |message| estimate_tokens(message) }
      return trailing if usage.nil?

      calculate_context_tokens(usage) + trailing
    end

    # Whether context usage has crossed the compaction threshold: it must leave
    # room for the summary work (reserve_tokens) inside the model's window. When
    # compaction is disabled, never compact. Port of pi's shouldCompact.
    def should_compact?(context_tokens, context_window, settings = DEFAULT_SETTINGS)
      return false unless settings.enabled

      context_tokens > context_window - settings.reserve_tokens
    end

    # Characters one content block contributes to the token estimate. A tool call
    # is its name plus the JSON of its arguments, matching pi's
    # safeJsonStringify(arguments) accounting.
    def block_chars(block)
      case block.type
      when :text then block.text.length
      when :thinking then block.thinking.length
      when :image then ESTIMATED_IMAGE_CHARS
      when :tool_call then block.name.length + safe_json(block.arguments).length
      else 0
      end
    end
    private_class_method :block_chars

    def safe_json(value)
      JSON.generate(value)
    rescue StandardError
      "[unserializable]"
    end
    private_class_method :safe_json
  end
end
