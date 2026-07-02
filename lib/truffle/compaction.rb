# frozen_string_literal: true

require "json"
require "set"
require_relative "message"
require_relative "session"
require_relative "compaction/utils"
require_relative "compaction/branch_summarization"

module Truffle
  # The decision layer for context compaction: how many context tokens a
  # conversation is using, and whether that has crossed the threshold where old
  # turns must be summarized to stay under the model's window.
  #
  # A faithful port of pi's compaction.ts: the trigger half
  # (calculateContextTokens, estimateTokens, estimateContextTokens, shouldCompact),
  # the retention cut-point selection (findCutPoint and friends), the prompt text
  # the summarizer feeds the model, and the prepareCompaction/compact assembly.
  # File tracking and conversation serialization live in compaction/utils.rb, the
  # port of pi's compaction/utils.ts. The model call that turns these prompts into
  # a summary runs through the provider seam; everything else here is pure.
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

    # The cut point a compaction selects: the index of the first session entry
    # kept after the summary, plus the split-turn bookkeeping. When the cut lands
    # inside a turn (on an assistant or tool entry rather than the user message
    # that began the turn), turn_start_index points at that user message and
    # split_turn is true, so the summarizer can fold the cut-off prefix of the
    # turn into the summary. Mirrors pi's CutPointResult.
    CutPoint = Struct.new(:first_kept_index, :turn_start_index, :split_turn, keyword_init: true)

    # Everything a compaction needs before any model call: where retained history
    # begins (first_kept_entry_id), the messages to fold into the history summary
    # (messages_to_summarize) and, for a split turn, the cut-off prefix to
    # summarize separately (turn_prefix_messages, split_turn), the size being
    # compacted away (tokens_before), the prior summary to extend when continuing
    # one (previous_summary), the file operations the dropped history touched
    # (file_ops), and the settings used. Pure; the model call happens in compact.
    # Mirrors pi's CompactionPreparation.
    Preparation = Struct.new(
      :first_kept_entry_id, :messages_to_summarize, :turn_prefix_messages,
      :split_turn, :tokens_before, :previous_summary, :file_ops, :settings,
      keyword_init: true
    )

    # The result of a compaction, ready to be persisted as a session compaction
    # entry: the summary that stands in for the dropped turns, the id where kept
    # history resumes, the context size that was compacted away, and the read and
    # modified file lists (so a later compaction can carry them forward). Mirrors
    # pi's CompactionResult.
    CompactionResult = Struct.new(
      :summary, :first_kept_entry_id, :tokens_before, :details, keyword_init: true
    )

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

    # Work out everything a compaction needs before any model call, for a session
    # path already resolved into chronological order. Returns nil when there is
    # nothing to compact: an empty path, or one whose last entry is already a
    # compaction. Otherwise it finds the cut point, the history to summarize, the
    # split-turn prefix when the cut lands inside a turn, the file operations the
    # dropped history touched (seeded from a prior compaction's details), and the
    # context size being compacted away. Port of pi's prepareCompaction.
    #
    # When a prior compaction sits on the path, summarization continues from it:
    # its summary becomes previous_summary and the window starts at the entry it
    # kept (or just after it when that entry is gone), so a session is summarized
    # incrementally rather than from scratch each time.
    def prepare_compaction(path_entries, settings = DEFAULT_SETTINGS)
      return nil if path_entries.empty? || path_entries.last[:type] == "compaction"

      prev_index = last_compaction_index(path_entries)
      previous_summary, boundary_start = previous_compaction_window(path_entries, prev_index)
      tokens_before = estimate_context_tokens(Session.build_context(path_entries).messages)

      cut = find_cut_point(path_entries, boundary_start, path_entries.length,
                           settings.keep_recent_tokens)
      first_kept = path_entries[cut.first_kept_index]
      unless first_kept && first_kept[:id]
        raise Error.new(:invalid_session, "First kept entry has no id - session may need migration")
      end

      build_preparation(
        entries: path_entries, cut: cut, prev_index: prev_index, boundary_start: boundary_start,
        previous_summary: previous_summary, tokens_before: tokens_before, settings: settings
      )
    end

    # Turn a Preparation into a finished summary by calling the model. With a
    # split turn it summarizes the history and the cut-off turn prefix separately
    # and joins them under a labeled divider (an empty history becomes the literal
    # "No prior history."); otherwise it summarizes the history alone. Either way
    # the read and modified file lists are appended as metadata tags, and the
    # result carries those lists so a later compaction can seed from them. A
    # Compaction::Error from the summarizer (aborted or provider error) propagates.
    # Port of pi's compact.
    def compact(preparation, provider, model, custom_instructions: nil, signal: nil)
      if preparation.first_kept_entry_id.nil? || preparation.first_kept_entry_id.empty?
        raise Error.new(:invalid_session, "First kept entry has no id - session may need migration")
      end

      summary = build_summary(preparation, provider, model, custom_instructions, signal)
      lists = compute_file_lists(preparation.file_ops)
      summary += format_file_operations(lists[:read_files], lists[:modified_files])

      CompactionResult.new(
        summary: summary,
        first_kept_entry_id: preparation.first_kept_entry_id,
        tokens_before: preparation.tokens_before,
        details: { read_files: lists[:read_files], modified_files: lists[:modified_files] }
      )
    end

    # The index of the last compaction entry on the path, or -1 when none. A
    # prior compaction is the point summarization continues from.
    def last_compaction_index(entries)
      (entries.length - 1).downto(0) do |i|
        return i if entries[i][:type] == "compaction"
      end
      -1
    end
    private_class_method :last_compaction_index

    # The prior summary to extend and the index where this compaction's window
    # begins. With no prior compaction the window is the whole path and there is
    # no prior summary. With one, the window starts at the entry that compaction
    # kept (or just after the compaction when that entry is no longer on the path,
    # matching pi's findIndex fallback). Returns [previous_summary, boundary_start].
    def previous_compaction_window(entries, prev_index)
      return [nil, 0] if prev_index.negative?

      prev = entries[prev_index]
      kept_index = entries.index { |entry| entry[:id] == prev[:first_kept_entry_id] }
      [prev[:summary], kept_index || (prev_index + 1)]
    end
    private_class_method :previous_compaction_window

    # Assemble the Preparation from a chosen cut: the history messages from the
    # window start up to where the kept tail begins (the turn start on a split,
    # otherwise the first kept entry), the split-turn prefix messages, and the
    # file operations both stretches touched (seeded from the prior compaction).
    def build_preparation(entries:, cut:, prev_index:, boundary_start:, previous_summary:,
                          tokens_before:, settings:)
      history_end = cut.split_turn ? cut.turn_start_index : cut.first_kept_index
      messages_to_summarize = messages_in_range(entries, boundary_start, history_end)
      turn_prefix_messages =
        cut.split_turn ? messages_in_range(entries, cut.turn_start_index, cut.first_kept_index) : []

      file_ops = extract_file_operations(messages_to_summarize, entries, prev_index)
      turn_prefix_messages.each { |message| extract_file_ops_from_message(message, file_ops) }

      Preparation.new(
        first_kept_entry_id: entries[cut.first_kept_index][:id],
        messages_to_summarize: messages_to_summarize,
        turn_prefix_messages: turn_prefix_messages,
        split_turn: cut.split_turn,
        tokens_before: tokens_before,
        previous_summary: previous_summary,
        file_ops: file_ops,
        settings: settings
      )
    end
    private_class_method :build_preparation

    # The messages from entries[from...to], skipping entries that produce none (a
    # compaction entry and the settings entries). Port of the getMessageFromEntry
    # ForCompaction walk over an index range.
    def messages_in_range(entries, from, to)
      (from...to).filter_map { |i| message_from_entry_for_compaction(entries[i]) }
    end
    private_class_method :messages_in_range

    # The Message an entry contributes to a compaction summary, or nil. A
    # compaction entry contributes nothing (its summary is not re-summarized), a
    # message entry becomes its Message, and a settings entry contributes nothing.
    # Port of pi's getMessageFromEntryForCompaction, narrowed to this port's entry
    # kinds (custom_message and branch_summary arrive with their session slices).
    def message_from_entry_for_compaction(entry)
      return nil if entry[:type] == "compaction"
      return Message.from_h(entry[:message]) if entry[:type] == "message"

      nil
    end
    private_class_method :message_from_entry_for_compaction

    # Collect the file operations a compacted stretch touched: seed from the prior
    # compaction's stored details (its read files as reads, its modified files as
    # edits, so they survive across successive compactions), then fold in every
    # message's own tool calls. Port of pi's extractFileOperations.
    def extract_file_operations(messages, entries, prev_index)
      file_ops = create_file_ops
      seed_file_ops_from_previous(file_ops, entries[prev_index]) unless prev_index.negative?
      messages.each { |message| extract_file_ops_from_message(message, file_ops) }
      file_ops
    end
    private_class_method :extract_file_operations

    # Seed an accumulator from a prior compaction entry's details. The details
    # hash is symbol-keyed in memory and string-keyed after a JSON round trip, so
    # both forms are read. A compaction written without details seeds nothing.
    def seed_file_ops_from_previous(file_ops, prev_entry)
      details = prev_entry[:details] || prev_entry["details"]
      return unless details.is_a?(Hash)

      read = details[:read_files] || details["read_files"]
      modified = details[:modified_files] || details["modified_files"]
      Array(read).each { |path| file_ops.read << path if path.is_a?(String) }
      Array(modified).each { |path| file_ops.edited << path if path.is_a?(String) }
    end
    private_class_method :seed_file_ops_from_previous

    # The summary body for a preparation, before file-operation tags. A split turn
    # summarizes the history and the cut-off prefix separately and joins them under
    # a labeled divider, with an empty history standing in as "No prior history.";
    # otherwise it summarizes the history alone.
    def build_summary(preparation, provider, model, custom_instructions, signal)
      unless split?(preparation)
        return history_summary(preparation, provider, model, custom_instructions,
                               signal)
      end

      history = if preparation.messages_to_summarize.empty?
                  "No prior history."
                else
                  history_summary(preparation, provider, model, custom_instructions, signal)
                end
      prefix = generate_turn_prefix_summary(
        provider, model, preparation.turn_prefix_messages,
        reserve_tokens: preparation.settings.reserve_tokens, signal: signal
      )
      "#{history}\n\n---\n\n**Turn Context (split turn):**\n\n#{prefix}"
    end
    private_class_method :build_summary

    # Whether a preparation summarizes a split turn (the cut landed inside a turn
    # and there is a prefix to summarize). A split with an empty prefix is treated
    # as a plain history summary, matching pi's `isSplitTurn && length > 0` guard.
    def split?(preparation)
      preparation.split_turn && !preparation.turn_prefix_messages.empty?
    end
    private_class_method :split?

    # Summarize a preparation's history messages, folding in its prior summary and
    # any custom focus. The shared call for the split and non-split paths.
    def history_summary(preparation, provider, model, custom_instructions, signal)
      generate_summary(
        provider, model, preparation.messages_to_summarize,
        reserve_tokens: preparation.settings.reserve_tokens, signal: signal,
        custom_instructions: custom_instructions, previous_summary: preparation.previous_summary
      )
    end
    private_class_method :history_summary

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
  end
end
