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

  # --- turning entries into summary input ------------------------------------

  # Fetch the stored entry hashes for a list of appended entry ids, in order,
  # the way collect_entries_for_branch_summary hands them to prepare.
  def entries_for(*ids)
    ids.map { |id| @session.entry(id) }
  end

  def test_maps_each_entry_kind_and_skips_the_ones_without_a_message
    user = @session.append_message(Truffle::Message.user("alpha"))
    assistant = @session.append_message(Truffle::Message.assistant(content: "beta"))
    tool = @session.append_message(
      Truffle::Message.tool(content: "result", tool_call_id: "call_1", name: "read")
    )
    model = @session.append_model_change(provider: "openai", model_id: "gpt-x")
    branch = @session.branch_with_summary(model, "explored elsewhere")
    compaction = @session.append_compaction(
      summary: "earlier work", first_kept_entry_id: user, tokens_before: 100
    )

    prepared = BranchSummarization.prepare_branch_entries(
      entries_for(user, assistant, tool, model, branch, compaction)
    )

    # The tool result and the model change carry no message, so they drop out;
    # the rest map oldest first, the two summaries wrapped as user turns.
    assert_equal(%i[user assistant user user], prepared.messages.map(&:role))
    assert_equal "alpha", prepared.messages[0].text
    assert_equal "beta", prepared.messages[1].text
    assert_includes prepared.messages[2].text, "explored elsewhere"
    assert_includes prepared.messages[3].text, "earlier work"
  end

  def test_seeds_file_operations_from_branch_summary_details
    root = @session.append_message(Truffle::Message.user("a"))
    branch = @session.branch_with_summary(
      root, "a digest",
      details: { read_files: ["read.rb"], modified_files: ["edit.rb"] }
    )

    prepared = BranchSummarization.prepare_branch_entries(entries_for(branch))

    assert_equal ["read.rb"], prepared.file_ops.read.to_a
    assert_equal ["edit.rb"], prepared.file_ops.edited.to_a
  end

  # --- token budget selection ------------------------------------------------

  # Three user turns of a known size: "x" * 40 is 40 chars, so ceil(40 / 4) is
  # ten tokens each, which makes the budget arithmetic below exact.
  def three_ten_token_turns
    first = @session.append_message(Truffle::Message.user("x" * 40))
    second = @session.append_message(Truffle::Message.user("y" * 40))
    third = @session.append_message(Truffle::Message.user("z" * 40))
    [first, second, third]
  end

  def test_zero_budget_keeps_every_message
    first, second, third = three_ten_token_turns

    prepared = BranchSummarization.prepare_branch_entries(entries_for(first, second, third))

    assert_equal 3, prepared.messages.length
    assert_equal 30, prepared.total_tokens
  end

  def test_budget_stops_before_the_message_that_would_overflow
    first, second, third = three_ten_token_turns

    # Newest first: third then second fit in twenty-five tokens; first would make
    # thirty, so it is left behind and only the newest two survive.
    prepared = BranchSummarization.prepare_branch_entries(
      entries_for(first, second, third), 25
    )

    assert_equal 20, prepared.total_tokens
    assert_equal ["y" * 40, "z" * 40], prepared.messages.map(&:text)
  end

  def test_keeps_an_overflowing_summary_when_it_still_fits_under_the_threshold
    summary = @session.branch_with_summary(nil, "the abandoned branch")
    tail_a = @session.append_message(Truffle::Message.user("x" * 40))
    tail_b = @session.append_message(Truffle::Message.user("y" * 40))

    # The two tails take twenty tokens, under nine tenths of twenty-five (22.5),
    # so the older summary is kept even though it pushes the total past budget.
    prepared = BranchSummarization.prepare_branch_entries(
      entries_for(summary, tail_a, tail_b), 25
    )

    assert_equal 3, prepared.messages.length
    assert_includes prepared.messages[0].text, "the abandoned branch"
  end

  def test_drops_an_overflowing_summary_once_the_total_reaches_the_threshold
    summary = @session.branch_with_summary(nil, "the abandoned branch")
    tail_a = @session.append_message(Truffle::Message.user("x" * 40))
    tail_b = @session.append_message(Truffle::Message.user("y" * 40))

    # Same twenty-token tail, but a budget of twenty-two puts the total at or over
    # nine tenths of it (19.8), so the summary boundary is not kept past the cut.
    prepared = BranchSummarization.prepare_branch_entries(
      entries_for(summary, tail_a, tail_b), 22
    )

    assert_equal 2, prepared.messages.length
    assert_equal ["x" * 40, "y" * 40], prepared.messages.map(&:text)
  end
end
