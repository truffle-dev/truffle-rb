# frozen_string_literal: true

require "set"
require_relative "../message"
require_relative "../session"
require_relative "utils"

module Truffle
  module Compaction
    # Branch summarization for conversation-tree navigation. A session is a tree:
    # editing an earlier turn opens a second child of it, so moving to a different
    # point can leave a branch of turns behind. Before that happens the abandoned
    # branch is summarized, so its context is not lost when the model no longer
    # sees those entries. This ports the front half of pi's
    # compaction/branch-summarization.ts: gathering the entries between where the
    # session is and where it is going, then turning them into the messages and
    # file lists a summary is built from. The summarizing model call is the
    # remaining slice.
    #
    # It reads the session only through the public entry(id) look-up, the entry
    # hash keys, and the public summary-wrap constants, the same read-only JSONL
    # contract compaction.rb walks; it never mutates the session or moves its
    # leaf. estimate_tokens and the file-operation helpers come from the shared
    # Compaction module (the decision layer and compaction/utils.rb).
    module BranchSummarization
      # The outcome of collecting a branch: the entries to summarize, oldest
      # first, and the deepest entry shared by the old and target paths (nil when
      # the two paths never meet). Mirrors pi's CollectEntriesResult. The member
      # is branch_entries rather than entries so it does not shadow Struct's own
      # Enumerable #entries.
      Collected = Struct.new(:branch_entries, :common_ancestor_id, keyword_init: true)

      # The outcome of turning collected entries into summary input: the messages
      # the summarizing model sees, oldest first; the file operations gathered
      # along the way; and the token total of the selected messages. Mirrors pi's
      # PrepareBranchEntriesResult.
      Prepared = Struct.new(:messages, :file_ops, :total_tokens, keyword_init: true)

      module_function

      # Collect the entries to summarize when navigating from old_leaf_id to
      # target_id. Walks from the old leaf back toward its deepest common ancestor
      # with the target, gathering the entries passed on the way in chronological
      # order. Compaction boundaries are not stops: those entries are included and
      # their own summaries become part of what is summarized. With no old
      # position there is nothing to summarize. Ports pi's
      # collectEntriesForBranchSummary.
      def collect_entries_for_branch_summary(session, old_leaf_id, target_id)
        return Collected.new(branch_entries: [], common_ancestor_id: nil) if old_leaf_id.nil?

        old_path = ancestor_ids(session, old_leaf_id)
        common_ancestor_id = deepest_common_ancestor(session, target_id, old_path)

        entries = []
        current = old_leaf_id
        while current && current != common_ancestor_id
          entry = session.entry(current)
          break unless entry

          entries << entry
          current = entry[:parent_id]
        end
        entries.reverse!

        Collected.new(branch_entries: entries, common_ancestor_id: common_ancestor_id)
      end

      # Turn collected branch entries into the messages a summary is built from,
      # oldest first, along with the file operations they touched. Entries that
      # carry no message (a model or thinking-level change, a bare label) are
      # skipped, and tool-result turns are dropped so the summary reads as the
      # conversation rather than its raw tool output. A token_budget of zero keeps
      # every message; a positive budget walks newest first and stops once the
      # next message would overflow, but still keeps that message when it is a
      # summary boundary and the total so far is under nine tenths of the budget,
      # so a branch or compaction summary is not lost to a tight cutoff. Ports
      # pi's prepareBranchEntries.
      def prepare_branch_entries(entries, token_budget = 0)
        file_ops = Compaction.create_file_ops

        entries.each do |entry|
          next unless entry[:type] == "branch_summary"
          next if entry[:from_hook] || entry["from_hook"]

          seed_branch_summary_file_ops(file_ops, entry)
        end

        messages = []
        total_tokens = 0

        entries.reverse_each do |entry|
          message = message_from_entry(entry)
          next unless message

          Compaction.extract_file_ops_from_message(message, file_ops)
          tokens = Compaction.estimate_tokens(message)

          if token_budget.positive? && total_tokens + tokens > token_budget
            if summary_entry?(entry) && total_tokens < token_budget * 0.9
              messages.unshift(message)
              total_tokens += tokens
            end
            break
          end

          messages.unshift(message)
          total_tokens += tokens
        end

        Prepared.new(messages: messages, file_ops: file_ops, total_tokens: total_tokens)
      end

      # The message an entry contributes to the summary, or nil when the entry
      # carries none. Narrowed to this port's entry kinds: a plain message (a
      # tool-result turn contributes nothing), a branch summary, or a compaction
      # summary, the last two wrapped through the session's public summary
      # constants so they read the same as when the session replays them. Mirrors
      # pi's getMessageFromEntry over the kinds this port stores.
      def message_from_entry(entry)
        case entry[:type]
        when "message"
          message = Message.from_h(entry[:message])
          message.role == :tool ? nil : message
        when "branch_summary"
          Message.user(Session::BRANCH_SUMMARY_PREFIX + entry[:summary] + Session::BRANCH_SUMMARY_SUFFIX)
        when "compaction"
          Message.user(Session::COMPACTION_SUMMARY_PREFIX + entry[:summary] + Session::COMPACTION_SUMMARY_SUFFIX)
        end
      end

      # Add the files a branch-summary entry recorded to the running file
      # operations: its read files as reads, its modified files as edits. Entries
      # written by a hook carry no user-visible file work and are skipped by the
      # caller. Reads both symbol and string detail keys, the same tolerance
      # compaction.rb's seed_file_ops_from_previous uses.
      def seed_branch_summary_file_ops(file_ops, entry)
        details = entry[:details] || entry["details"]
        return unless details.is_a?(Hash)

        read = details[:read_files] || details["read_files"]
        modified = details[:modified_files] || details["modified_files"]
        Array(read).each { |path| file_ops.read << path if path.is_a?(String) }
        Array(modified).each { |path| file_ops.edited << path if path.is_a?(String) }
      end

      # Whether an entry is a summary boundary, the kind kept past a tight budget
      # cutoff so an earlier branch or compaction summary is not dropped.
      def summary_entry?(entry)
        %w[compaction branch_summary].include?(entry[:type])
      end

      # The set of entry ids on the path from leaf_id up to the root, so a
      # target-path walk can test membership. Mirrors the Set pi builds from
      # getBranch(oldLeafId).
      def ancestor_ids(session, leaf_id)
        ids = Set.new
        current = leaf_id
        while current
          entry = session.entry(current)
          break unless entry

          ids << current
          current = entry[:parent_id]
        end
        ids
      end

      # The deepest entry on target_id's root path that also lies on old_path.
      # Walking from the target up toward the root visits leaf-first, so the first
      # id found on old_path is the deepest shared ancestor; nil when the two
      # paths never meet.
      def deepest_common_ancestor(session, target_id, old_path)
        current = target_id
        while current
          return current if old_path.include?(current)

          entry = session.entry(current)
          break unless entry

          current = entry[:parent_id]
        end
        nil
      end

      private_class_method :ancestor_ids, :deepest_common_ancestor,
                           :message_from_entry, :seed_branch_summary_file_ops, :summary_entry?
    end
  end
end
