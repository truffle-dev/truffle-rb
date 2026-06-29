# frozen_string_literal: true

require "json"
require_relative "message"

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

    # The cut point a compaction selects: the index of the first session entry
    # kept after the summary, plus the split-turn bookkeeping. When the cut lands
    # inside a turn (on an assistant or tool entry rather than the user message
    # that began the turn), turn_start_index points at that user message and
    # split_turn is true, so the summarizer can fold the cut-off prefix of the
    # turn into the summary. Mirrors pi's CutPointResult.
    CutPoint = Struct.new(:first_kept_index, :turn_start_index, :split_turn, keyword_init: true)

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

    # Choose where to cut the session for a compaction: keep roughly the most
    # recent keep_recent_tokens of conversation, snapped to a turn boundary, and
    # summarize everything before it. entries is the session path (the list #context
    # walks); the window is entries[start_index...end_index] (end_index exclusive),
    # so a prior compaction can be excluded by raising start_index. Port of pi's
    # findCutPoint.
    #
    # The walk runs backward from the end summing estimate_tokens of each message
    # entry until the recent budget is met, then snaps to the first valid cut point
    # at or after that entry, never landing mid tool-result. A user message starts a
    # turn, so cutting there is a clean boundary; cutting on an assistant or tool
    # entry splits a turn, recorded via turn_start_index and split_turn so the
    # summarizer can absorb the turn's cut-off prefix.
    def find_cut_point(entries, start_index, end_index, keep_recent_tokens)
      cut_points = valid_cut_points(entries, start_index, end_index)
      if cut_points.empty?
        return CutPoint.new(first_kept_index: start_index, turn_start_index: -1, split_turn: false)
      end

      recent = recent_cut_index(entries, cut_points, start_index, end_index, keep_recent_tokens)
      cut_index = settle_cut_index(entries, recent, start_index)
      user_cut = message_role(entries[cut_index]) == :user
      turn_start = user_cut ? -1 : find_turn_start_index(entries, cut_index, start_index)
      CutPoint.new(
        first_kept_index: cut_index,
        turn_start_index: turn_start,
        split_turn: !user_cut && turn_start != -1
      )
    end

    # The user-visible message that begins the turn containing entry_index, walking
    # backward to start_index; -1 when none is found. Port of findTurnStartIndex.
    # (pi also stops at a bashExecution message or a branch/custom-message entry;
    # this port has only the user role until those entry kinds exist.)
    def find_turn_start_index(entries, entry_index, start_index)
      entry_index.downto(start_index) do |i|
        return i if message_role(entries[i]) == :user
      end
      -1
    end

    # The indices in entries[start_index...end_index] a compaction may cut at: the
    # user and assistant message boundaries. A tool result is never a cut point
    # (cutting there would orphan it from its call), and the non-message settings
    # entries are not turn boundaries. Port of findValidCutPoints, narrowed to this
    # port's role set.
    def valid_cut_points(entries, start_index, end_index)
      (start_index...end_index).select do |i|
        %i[user assistant].include?(message_role(entries[i]))
      end
    end
    private_class_method :valid_cut_points

    # Walk backward from the end of the window summing each message entry's tokens
    # until keep_recent_tokens is reached, then return the first valid cut point at
    # or after that entry. When the recent budget is never met (the kept tail is the
    # whole window), the earliest cut point stands. The inner search keeps the
    # earliest cut point when none sits at or after the stopping entry, matching pi.
    def recent_cut_index(entries, cut_points, start_index, end_index, keep_recent_tokens)
      accumulated = 0
      (end_index - 1).downto(start_index) do |i|
        next unless message_role(entries[i])

        accumulated += estimate_tokens(Message.from_h(entries[i][:message]))
        next if accumulated < keep_recent_tokens

        return cut_points.find { |c| c >= i } || cut_points.first
      end
      cut_points.first
    end
    private_class_method :recent_cut_index

    # Pull the cut back over any non-message, non-compaction entries that sit just
    # before it (settings changes), so the first kept entry is a real boundary and
    # not a bare settings line. Stops at the window start, a message, or a
    # compaction. Port of findCutPoint's trailing while loop.
    def settle_cut_index(entries, cut_index, start_index)
      while cut_index > start_index
        prev = entries[cut_index - 1]
        break if prev[:type] == "compaction" || message_entry?(prev)

        cut_index -= 1
      end
      cut_index
    end
    private_class_method :settle_cut_index

    # Whether a session entry is a stored message (as opposed to a settings or
    # compaction entry).
    def message_entry?(entry)
      entry[:type] == "message"
    end
    private_class_method :message_entry?

    # The role of a message entry as a symbol, or nil for a non-message entry. The
    # stored message hash is symbol-keyed with a symbol role in memory and
    # string-keyed after a JSON round trip, so both forms are folded.
    def message_role(entry)
      return nil unless message_entry?(entry)

      raw = entry[:message]
      role = raw[:role] || raw["role"]
      role&.to_sym
    end
    private_class_method :message_role

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
