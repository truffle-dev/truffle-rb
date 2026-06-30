# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

# Branching and labels on the session tree, a port of pi's SessionManager#branch /
# resetLeaf / getChildren / appendLabelChange / getLabel. Entries form a tree
# through parent_id; moving the leaf back and appending opens a second child
# (a branch) without touching the abandoned path, and any entry can carry a user
# label that rides along as its own entry but never enters the model's context.
# Files live in a temp dir so the suite stays hermetic.
class TestSessionBranching < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("truffle-session-branch")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def texts(messages)
    messages.map(&:text)
  end

  def load_session(session)
    session.flush
    Truffle::Session.load(session.file)
  end

  def test_branch_moves_the_leaf_to_an_earlier_entry
    session = Truffle::Session.create(dir: @dir, cwd: "/work")
    first = session.append_message(Truffle::Message.user("a"))
    session.append_message(Truffle::Message.assistant(content: "b"))

    session.branch(first)

    assert_equal first, session.leaf_id
  end

  def test_branch_opens_a_second_child_and_context_follows_it
    session = Truffle::Session.create(dir: @dir, cwd: "/work")
    first = session.append_message(Truffle::Message.user("a"))
    session.append_message(Truffle::Message.assistant(content: "b"))

    session.branch(first)
    session.append_message(Truffle::Message.user("c"))

    assert_equal %w[a c], texts(session.context.messages)
    assert_equal 2, session.children(first).length
  end

  def test_the_abandoned_branch_stays_on_disk_and_is_still_walkable
    session = Truffle::Session.create(dir: @dir, cwd: "/work")
    first = session.append_message(Truffle::Message.user("a"))
    abandoned = session.append_message(Truffle::Message.assistant(content: "b"))

    session.branch(first)
    session.append_message(Truffle::Message.user("c"))

    assert_equal %w[a b], texts(session.messages(leaf_id: abandoned))
    assert_equal %w[a c], texts(session.messages)
  end

  def test_branch_raises_on_an_unknown_entry
    session = Truffle::Session.create(dir: @dir, cwd: "/work")

    assert_raises(ArgumentError) { session.branch("nope") }
  end

  def test_reset_leaf_starts_a_new_root
    session = Truffle::Session.create(dir: @dir, cwd: "/work")
    session.append_message(Truffle::Message.user("a"))

    session.reset_leaf
    fresh = session.append_message(Truffle::Message.user("b"))

    assert_nil session.entry(fresh)[:parent_id]
    assert_equal %w[b], texts(session.messages)
  end

  def test_children_of_nil_are_the_root_entries
    session = Truffle::Session.create(dir: @dir, cwd: "/work")
    root = session.append_message(Truffle::Message.user("a"))
    session.append_message(Truffle::Message.assistant(content: "b"))

    root_ids = session.children(nil).map { |entry| entry[:id] }

    assert_equal [root], root_ids
  end

  def test_append_label_change_sets_a_label_readable_by_label
    session = Truffle::Session.create(dir: @dir, cwd: "/work")
    target = session.append_message(Truffle::Message.user("a"))

    session.append_label_change(target, "checkpoint")

    assert_equal "checkpoint", session.label(target)
  end

  def test_a_label_entry_advances_the_leaf_but_stays_out_of_context
    session = Truffle::Session.create(dir: @dir, cwd: "/work")
    target = session.append_message(Truffle::Message.user("a"))

    label_id = session.append_label_change(target, "mark")

    assert_equal label_id, session.leaf_id
    assert_equal %w[a], texts(session.context.messages)
  end

  def test_append_label_change_clears_with_an_empty_label_last_write_winning
    session = Truffle::Session.create(dir: @dir, cwd: "/work")
    target = session.append_message(Truffle::Message.user("a"))

    session.append_label_change(target, "first")
    session.append_label_change(target, "")

    assert_nil session.label(target)
  end

  def test_append_label_change_raises_on_an_unknown_target
    session = Truffle::Session.create(dir: @dir, cwd: "/work")

    assert_raises(ArgumentError) { session.append_label_change("nope", "x") }
  end

  def test_labels_survive_a_reload
    session = Truffle::Session.create(dir: @dir, cwd: "/work")
    target = session.append_message(Truffle::Message.user("a"))
    session.append_label_change(target, "kept")

    reloaded = load_session(session)

    assert_equal "kept", reloaded.label(target)
  end

  def test_a_cleared_label_stays_cleared_after_reload
    session = Truffle::Session.create(dir: @dir, cwd: "/work")
    target = session.append_message(Truffle::Message.user("a"))
    session.append_label_change(target, "temp")
    session.append_label_change(target, nil)

    reloaded = load_session(session)

    assert_nil reloaded.label(target)
  end

  def test_branch_with_summary_moves_the_leaf_like_branch
    session = Truffle::Session.create(dir: @dir, cwd: "/work")
    first = session.append_message(Truffle::Message.user("a"))
    session.append_message(Truffle::Message.assistant(content: "b"))

    summary_id = session.branch_with_summary(first, "we tried b and abandoned it")

    assert_equal summary_id, session.leaf_id
    assert_equal first, session.entry(summary_id)[:parent_id]
  end

  def test_branch_with_summary_folds_the_digest_into_context_as_a_user_message
    session = Truffle::Session.create(dir: @dir, cwd: "/work")
    first = session.append_message(Truffle::Message.user("a"))
    session.append_message(Truffle::Message.assistant(content: "b"))

    session.branch_with_summary(first, "we tried b and abandoned it")
    session.append_message(Truffle::Message.user("c"))

    messages = session.context.messages

    assert_equal %i[user user user], messages.map(&:role)
    assert_equal "a", messages[0].text
    assert_includes messages[1].text, "we tried b and abandoned it"
    assert_equal "c", messages[2].text
  end

  def test_the_branch_summary_message_wraps_the_summary_for_the_model
    session = Truffle::Session.create(dir: @dir, cwd: "/work")
    first = session.append_message(Truffle::Message.user("a"))

    session.branch_with_summary(first, "digest text")

    digest = session.context.messages.last.text

    assert_includes digest, "a summary of a branch that this conversation came back from"
    assert_includes digest, "<summary>\ndigest text\n</summary>"
  end

  def test_branch_with_summary_to_nil_starts_a_fresh_root_carrying_the_digest
    session = Truffle::Session.create(dir: @dir, cwd: "/work")
    session.append_message(Truffle::Message.user("a"))

    summary_id = session.branch_with_summary(nil, "abandoned the whole thing")
    session.append_message(Truffle::Message.user("b"))

    assert_nil session.entry(summary_id)[:parent_id]
    assert_equal "root", session.entry(summary_id)[:from_id]
    assert_includes session.context.messages.first.text, "abandoned the whole thing"
    assert_equal "b", session.context.messages.last.text
  end

  def test_branch_with_summary_raises_on_an_unknown_entry
    session = Truffle::Session.create(dir: @dir, cwd: "/work")

    assert_raises(ArgumentError) { session.branch_with_summary("nope", "x") }
  end

  def test_branch_summary_survives_a_reload
    session = Truffle::Session.create(dir: @dir, cwd: "/work")
    first = session.append_message(Truffle::Message.user("a"))
    session.branch_with_summary(first, "kept digest")
    session.append_message(Truffle::Message.user("b"))

    reloaded = load_session(session)

    assert_includes reloaded.context.messages[1].text, "kept digest"
    assert_equal %w[a b], [reloaded.context.messages[0].text, reloaded.context.messages[2].text]
  end

  def test_branch_summary_stores_optional_details_and_omits_them_when_absent
    session = Truffle::Session.create(dir: @dir, cwd: "/work")
    first = session.append_message(Truffle::Message.user("a"))

    with_details = session.branch_with_summary(first, "x", details: { "files" => ["a.rb"] })
    without_details = session.branch_with_summary(first, "y")

    assert_equal({ "files" => ["a.rb"] }, session.entry(with_details)[:details])
    refute session.entry(without_details).key?(:details)
  end
end
