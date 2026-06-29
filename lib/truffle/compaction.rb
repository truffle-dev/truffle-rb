# frozen_string_literal: true

require "json"
require_relative "message"

module Truffle
  # The decision layer for context compaction: how many context tokens a
  # conversation is using, and whether that has crossed the threshold where old
  # turns must be summarized to stay under the model's window.
  #
  # A faithful port of pi's compaction
  # (packages/agent/src/harness/compaction/{compaction,utils}.ts): the trigger half
  # (calculateContextTokens, estimateTokens, estimateContextTokens, shouldCompact),
  # the retention cut-point selection (findCutPoint and friends), and the prompt
  # building the summarizer feeds the model (serializeConversation and the prompt
  # text). Everything here is pure and offline, so it can be checked exactly. The
  # model call that turns these prompts into a summary is a separate slice.
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

    # A tool result is clipped before it goes into a summary prompt, so one noisy
    # command output cannot crowd out the conversation. pi's TOOL_RESULT_MAX_CHARS.
    TOOL_RESULT_MAX_CHARS = 2000

    # The system prompt for the summarizing model: read the conversation, emit only
    # the structured summary, do not continue the conversation. Verbatim from pi.
    SUMMARIZATION_SYSTEM_PROMPT =
      "You are a context summarization assistant. Your task is to read a " \
      "conversation between a user and an AI assistant, then produce a structured " \
      "summary following the exact format specified.\n\nDo NOT continue the " \
      "conversation. Do NOT respond to any questions in the conversation. ONLY " \
      "output the structured summary."

    # The instruction appended after the conversation when there is no prior
    # summary: produce a fresh structured checkpoint in pi's exact section format.
    SUMMARIZATION_PROMPT = <<~PROMPT.chomp
      The messages above are a conversation to summarize. Create a structured context checkpoint summary that another LLM will use to continue the work.

      Use this EXACT format:

      ## Goal
      [What is the user trying to accomplish? Can be multiple items if the session covers different tasks.]

      ## Constraints & Preferences
      - [Any constraints, preferences, or requirements mentioned by user]
      - [Or "(none)" if none were mentioned]

      ## Progress
      ### Done
      - [x] [Completed tasks/changes]

      ### In Progress
      - [ ] [Current work]

      ### Blocked
      - [Issues preventing progress, if any]

      ## Key Decisions
      - **[Decision]**: [Brief rationale]

      ## Next Steps
      1. [Ordered list of what should happen next]

      ## Critical Context
      - [Any data, examples, or references needed to continue]
      - [Or "(none)" if not applicable]

      Keep each section concise. Preserve exact file paths, function names, and error messages.
    PROMPT

    # The instruction used when a prior summary exists: fold the new messages into
    # it, preserving what was there. Verbatim from pi.
    UPDATE_SUMMARIZATION_PROMPT = <<~PROMPT.chomp
      The messages above are NEW conversation messages to incorporate into the existing summary provided in <previous-summary> tags.

      Update the existing structured summary with new information. RULES:
      - PRESERVE all existing information from the previous summary
      - ADD new progress, decisions, and context from the new messages
      - UPDATE the Progress section: move items from "In Progress" to "Done" when completed
      - UPDATE "Next Steps" based on what was accomplished
      - PRESERVE exact file paths, function names, and error messages
      - If something is no longer relevant, you may remove it

      Use this EXACT format:

      ## Goal
      [Preserve existing goals, add new ones if the task expanded]

      ## Constraints & Preferences
      - [Preserve existing, add new ones discovered]

      ## Progress
      ### Done
      - [x] [Include previously done items AND newly completed items]

      ### In Progress
      - [ ] [Current work - update based on progress]

      ### Blocked
      - [Current blockers - remove if resolved]

      ## Key Decisions
      - **[Decision]**: [Brief rationale] (preserve all previous, add new)

      ## Next Steps
      1. [Update based on current state]

      ## Critical Context
      - [Preserve important context, add new if needed]

      Keep each section concise. Preserve exact file paths, function names, and error messages.
    PROMPT

    # The instruction used to summarize the cut-off prefix of a split turn, so the
    # retained suffix still has its setup. Verbatim from pi.
    TURN_PREFIX_SUMMARIZATION_PROMPT = <<~PROMPT.chomp
      This is the PREFIX of a turn that was too large to keep. The SUFFIX (recent work) is retained.

      Summarize the prefix to provide context for the retained suffix:

      ## Original Request
      [What did the user ask for in this turn?]

      ## Early Progress
      - [Key decisions and work done in the prefix]

      ## Context for Suffix
      - [Information needed to understand the retained recent work]

      Be concise. Focus on what's needed to understand the kept suffix.
    PROMPT

    # A compaction step that could not produce a summary. kind is :aborted when
    # the run was cancelled or :summarization_failed when the provider returned an
    # error, so the caller can tell a deliberate stop from a real failure. Mirrors
    # pi's CompactionError; the :invalid_session kind arrives with the compact step.
    class Error < StandardError
      attr_reader :kind

      def initialize(kind, message)
        @kind = kind
        super(message)
      end
    end

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

    # Render the messages a cut keeps into the plain-text conversation body the
    # summarizing model reads. Each message becomes one or more labeled parts
    # joined by a blank line: a user turn is its text, an assistant turn is up to
    # three parts (thinking, then text, then tool calls) in that fixed order, and a
    # tool result is its text clipped to TOOL_RESULT_MAX_CHARS. Empty turns and the
    # system prompt contribute nothing. Port of pi's serializeConversation.
    def serialize_conversation(messages)
      parts = []
      messages.each { |message| append_serialized(parts, message) }
      parts.join("\n\n")
    end

    # Build the full prompt text the summarizer reads: the conversation wrapped in
    # <conversation> tags, the prior summary in <previous-summary> tags when one
    # exists, then the base instruction (the update variant when continuing a
    # summary, otherwise the fresh-checkpoint variant). A custom focus is appended
    # to the base instruction. Port of pi's generateSummary prompt assembly, minus
    # the provider call and token budgeting.
    def summarization_prompt(messages, previous_summary: nil, custom_instructions: nil)
      base = previous_summary ? UPDATE_SUMMARIZATION_PROMPT : SUMMARIZATION_PROMPT
      base = "#{base}\n\nAdditional focus: #{custom_instructions}" if custom_instructions
      text = "<conversation>\n#{serialize_conversation(messages)}\n</conversation>\n\n"
      text += "<previous-summary>\n#{previous_summary}\n</previous-summary>\n\n" if previous_summary
      text + base
    end

    # Build the prompt that summarizes the cut-off prefix of a split turn. Port of
    # pi's generateTurnPrefixSummary prompt assembly, minus the provider call.
    def turn_prefix_prompt(messages)
      "<conversation>\n#{serialize_conversation(messages)}\n</conversation>\n\n" \
        "#{TURN_PREFIX_SUMMARIZATION_PROMPT}"
    end

    # Summarize a stretch of history into a structured checkpoint by asking the
    # model. Builds the prompt (folding in a prior summary or a custom focus when
    # given), caps the summary's own output at 0.8 of the reserve budget, and runs
    # the summarizer. Returns the summary text, or raises Compaction::Error when
    # the run is aborted or the provider errors. Port of pi's generateSummary,
    # without the thinking-level option (this port's provider seam has no per-call
    # reasoning control yet).
    def generate_summary(provider, model, messages, reserve_tokens:, signal: nil,
                         custom_instructions: nil, previous_summary: nil)
      prompt = summarization_prompt(
        messages, previous_summary: previous_summary, custom_instructions: custom_instructions
      )
      max_tokens = max_summary_tokens(model, reserve_tokens, 0.8)
      run_summarizer(provider, model, prompt, max_tokens, signal)
    end

    # Summarize the cut-off prefix of a split turn. Same shape as generate_summary
    # but with the turn-prefix prompt and a tighter 0.5-of-reserve output cap, since
    # this summary is auxiliary to the retained suffix. Port of pi's
    # generateTurnPrefixSummary.
    def generate_turn_prefix_summary(provider, model, messages, reserve_tokens:, signal: nil)
      prompt = turn_prefix_prompt(messages)
      max_tokens = max_summary_tokens(model, reserve_tokens, 0.5)
      run_summarizer(provider, model, prompt, max_tokens, signal)
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

    # Append the labeled parts for one message to the running parts list. The
    # system prompt and empty turns add nothing, matching pi's role switch.
    def append_serialized(parts, message)
      case message.role
      when :user then append_text_part(parts, "[User]", message)
      when :assistant then append_assistant(parts, message)
      when :tool then append_tool_result(parts, message)
      end
    end
    private_class_method :append_serialized

    # A single labeled part from a message's joined text, skipped when empty. Used
    # for the user turn; the tool result clips first and so has its own helper.
    def append_text_part(parts, label, message)
      text = message.text
      parts << "#{label}: #{text}" if text && !text.empty?
    end
    private_class_method :append_text_part

    # The assistant turn's parts: thinking, then text, then tool calls, each
    # emitted only when present and always in that order regardless of block order.
    def append_assistant(parts, message)
      thinking = message.content.grep(Content::Thinking).map(&:thinking)
      text = message.content.grep(Content::Text).map(&:text)
      tool_calls = message.content.grep(ToolCall).map { |call| serialize_tool_call(call) }

      parts << "[Assistant thinking]: #{thinking.join("\n")}" unless thinking.empty?
      parts << "[Assistant]: #{text.join("\n")}" unless text.empty?
      parts << "[Assistant tool calls]: #{tool_calls.join("; ")}" unless tool_calls.empty?
    end
    private_class_method :append_assistant

    # One tool call rendered as name(k=json(v), ...), the arguments in insertion
    # order. Mirrors pi's Object.entries(args) walk.
    def serialize_tool_call(call)
      args = call.arguments.map { |key, value| "#{key}=#{safe_json(value)}" }.join(", ")
      "#{call.name}(#{args})"
    end
    private_class_method :serialize_tool_call

    # The tool result part, its text clipped to the per-result budget and skipped
    # when empty.
    def append_tool_result(parts, message)
      text = message.text
      return if text.nil? || text.empty?

      parts << "[Tool result]: #{truncate_for_summary(text, TOOL_RESULT_MAX_CHARS)}"
    end
    private_class_method :append_tool_result

    # Clip text to max_chars, appending a note of how many characters were dropped.
    # A text at or under the budget is returned unchanged. Port of pi's
    # truncateForSummary.
    def truncate_for_summary(text, max_chars)
      return text if text.length <= max_chars

      dropped = text.length - max_chars
      "#{text[0, max_chars]}\n\n[... #{dropped} more characters truncated]"
    end
    private_class_method :truncate_for_summary

    # Run one summarization call: wrap the prompt as a single user turn under the
    # summarizer system prompt, call the provider, and turn the response into the
    # summary text or a Compaction::Error. The signal is checked at the boundary
    # before the call (cooperative cancellation, matching the agent loop), and an
    # aborted or errored response maps to the matching error kind.
    def run_summarizer(provider, model, prompt_text, max_tokens, signal)
      raise Error.new(:aborted, "Summarization aborted") if signal&.aborted?

      messages = [Message.system(SUMMARIZATION_SYSTEM_PROMPT), Message.user(prompt_text)]
      response = provider.chat(messages: messages, model: model.id, max_tokens: max_tokens)

      case response.stop_reason
      when StopReason::ABORTED
        raise Error.new(:aborted, response.error_message || "Summarization aborted")
      when StopReason::ERROR
        raise Error.new(:summarization_failed,
                        "Summarization failed: #{response.error_message || "Unknown error"}")
      end

      summary_text(response)
    end
    private_class_method :run_summarizer

    # The output-token budget for a summary: a fraction of the reserve, but never
    # more than the model can emit. A model that does not report a max output (0)
    # is left uncapped by the model, so only the reserve fraction applies. Port of
    # generateSummary's maxTokens computation.
    def max_summary_tokens(model, reserve_tokens, factor)
      budget = (factor * reserve_tokens).floor
      cap = model.max_output.positive? ? model.max_output : Float::INFINITY
      [budget, cap].min
    end
    private_class_method :max_summary_tokens

    # The summary text from a response: its Text blocks joined by newlines (pi
    # joins with "\n"), empty when the turn carried no text.
    def summary_text(response)
      response.message.content.grep(Content::Text).map(&:text).join("\n")
    end
    private_class_method :summary_text

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
