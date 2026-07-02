# frozen_string_literal: true

require "set"

module Truffle
  module Compaction
    # Branch summarization for conversation-tree navigation. A session is a tree:
    # editing an earlier turn opens a second child of it, so moving to a different
    # point can leave a branch of turns behind. Before that happens the abandoned
    # branch is summarized, so its context is not lost when the model no longer
    # sees those entries. This is the entry-collection half of pi's
    # compaction/branch-summarization.ts: gathering the entries between where the
    # session is and where it is going. The later slices (turning those entries
    # into messages, and the summarizing model call) build on what this returns.
    #
    # It reads the session only through the public entry(id) look-up and the
    # entry :parent_id/:id keys, the same read-only JSONL contract compaction.rb
    # walks; it never mutates the session or moves its leaf.
    module BranchSummarization
      # The outcome of collecting a branch: the entries to summarize, oldest
      # first, and the deepest entry shared by the old and target paths (nil when
      # the two paths never meet). Mirrors pi's CollectEntriesResult. The member
      # is branch_entries rather than entries so it does not shadow Struct's own
      # Enumerable #entries.
      Collected = Struct.new(:branch_entries, :common_ancestor_id, keyword_init: true)

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

      private_class_method :ancestor_ids, :deepest_common_ancestor
    end
  end
end
