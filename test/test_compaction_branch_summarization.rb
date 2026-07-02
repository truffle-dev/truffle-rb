# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# Entry collection for branch summarization: when the session moves to a
# different point in the conversation tree, gather the entries on the branch it
# leaves behind so they can later be summarized. Exercised against a real
# Session so the tree walk is tested through the actual entry(id)/parent_id
# contract, not a stub that could drift from it.
class TestCompactionBranchSummarization < Minitest::Test
  BranchSummarization = Truffle::Compaction::BranchSummarization

  def setup
    @dir = Dir.mktmpdir("truffle-branch-summary-")
    @session = Truffle::Session.create(dir: @dir, cwd: "/work")
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
  end

  # --- no old position -------------------------------------------------------

  def test_nil_old_leaf_summarizes_nothing
    target = @session.append_message(Truffle::Message.user("only turn"))

    result = BranchSummarization.collect_entries_for_branch_summary(@session, nil, target)

    assert_empty result.branch_entries
    assert_nil result.common_ancestor_id
  end

  # --- the common branching case ---------------------------------------------

  def test_collects_the_abandoned_branch_up_to_the_common_ancestor
    root = @session.append_message(Truffle::Message.user("a"))
    old_mid = @session.append_message(Truffle::Message.assistant(content: "b"))
    old_leaf = @session.append_message(Truffle::Message.user("c"))

    # Re-edit the root's turn: branch back to it and grow a second child path.
    @session.branch(root)
    @session.append_message(Truffle::Message.user("d"))
    target = @session.append_message(Truffle::Message.assistant(content: "e"))

    result = BranchSummarization.collect_entries_for_branch_summary(@session, old_leaf, target)

    # The abandoned branch is root's first child path below the shared root,
    # returned oldest first, and the shared ancestor is the root itself.
    assert_equal([old_mid, old_leaf], result.branch_entries.map { |entry| entry[:id] })
    assert_equal root, result.common_ancestor_id
  end

  # --- target on the same path -----------------------------------------------

  def test_target_that_is_an_ancestor_of_the_old_leaf
    root = @session.append_message(Truffle::Message.user("a"))
    mid = @session.append_message(Truffle::Message.assistant(content: "b"))
    old_leaf = @session.append_message(Truffle::Message.user("c"))

    # Navigating straight back up the current path: the target is the ancestor,
    # so only the entries below it are collected.
    result = BranchSummarization.collect_entries_for_branch_summary(@session, old_leaf, root)

    assert_equal([mid, old_leaf], result.branch_entries.map { |entry| entry[:id] })
    assert_equal root, result.common_ancestor_id
  end

  def test_target_equal_to_old_leaf_collects_nothing
    @session.append_message(Truffle::Message.user("a"))
    leaf = @session.append_message(Truffle::Message.assistant(content: "b"))

    result = BranchSummarization.collect_entries_for_branch_summary(@session, leaf, leaf)

    assert_empty result.branch_entries
    assert_equal leaf, result.common_ancestor_id
  end

  # --- disjoint roots --------------------------------------------------------

  def test_paths_that_share_no_ancestor
    old_leaf = @session.append_message(Truffle::Message.user("a"))
    old_mid = @session.append_message(Truffle::Message.assistant(content: "b"))
    old_top = @session.append_message(Truffle::Message.user("c"))

    # Reset before any entry so the next append is a fresh, second root.
    @session.reset_leaf
    other_root = @session.append_message(Truffle::Message.user("x"))
    target = @session.append_message(Truffle::Message.assistant(content: "y"))

    result = BranchSummarization.collect_entries_for_branch_summary(@session, old_top, target)

    # No common ancestor: the whole old path, root included, is collected.
    assert_equal([old_leaf, old_mid, old_top], result.branch_entries.map { |entry| entry[:id] })
    assert_nil result.common_ancestor_id
    refute_includes result.branch_entries.map { |entry| entry[:id] }, other_root
  end

  # --- unknown ids -----------------------------------------------------------

  def test_unknown_old_leaf_collects_nothing
    target = @session.append_message(Truffle::Message.user("a"))

    result = BranchSummarization.collect_entries_for_branch_summary(@session, "missing", target)

    assert_empty result.branch_entries
    assert_nil result.common_ancestor_id
  end

  def test_unknown_target_leaves_the_old_path_without_a_common_ancestor
    old_leaf = @session.append_message(Truffle::Message.user("a"))
    top = @session.append_message(Truffle::Message.assistant(content: "b"))

    result = BranchSummarization.collect_entries_for_branch_summary(@session, top, "missing")

    assert_equal([old_leaf, top], result.branch_entries.map { |entry| entry[:id] })
    assert_nil result.common_ancestor_id
  end
end
