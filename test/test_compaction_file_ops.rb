# frozen_string_literal: true

require "test_helper"

# The file-operation layer of compaction: collecting the read/write/edit paths
# from an assistant turn's tool calls, splitting them into read-only and
# modified lists, and rendering them as the metadata tags a compaction summary
# carries. Pure and offline, ported from pi's compaction/utils.ts.
class TestCompactionFileOps < Minitest::Test
  Compaction = Truffle::Compaction

  def assistant_with(*calls)
    Truffle::Message.assistant(tool_calls: calls)
  end

  def call(name, args)
    Truffle::ToolCall.new(id: "1", name: name, arguments: args)
  end

  def test_create_file_ops_starts_empty
    ops = Compaction.create_file_ops

    assert_empty ops.read
    assert_empty ops.written
    assert_empty ops.edited
  end

  def test_extract_records_read_write_and_edit_paths
    ops = Compaction.create_file_ops
    message = assistant_with(
      call("read", { "path" => "a.rb" }),
      call("write", { "path" => "b.rb" }),
      call("edit", { "path" => "c.rb" })
    )

    Compaction.extract_file_ops_from_message(message, ops)

    assert_equal Set["a.rb"], ops.read
    assert_equal Set["b.rb"], ops.written
    assert_equal Set["c.rb"], ops.edited
  end

  def test_extract_ignores_non_assistant_messages
    ops = Compaction.create_file_ops
    user = Truffle::Message.user("read a.rb please")

    Compaction.extract_file_ops_from_message(user, ops)

    assert_empty ops.read
  end

  def test_extract_ignores_tools_that_are_not_file_operations
    ops = Compaction.create_file_ops
    message = assistant_with(call("bash", { "path" => "x.rb", "command" => "ls" }))

    Compaction.extract_file_ops_from_message(message, ops)

    assert_empty ops.read
    assert_empty ops.written
    assert_empty ops.edited
  end

  def test_extract_ignores_a_call_without_a_string_path
    ops = Compaction.create_file_ops
    message = assistant_with(
      call("read", { "pattern" => "*.rb" }), # no path key
      call("read", { "path" => 42 })         # non-string path
    )

    Compaction.extract_file_ops_from_message(message, ops)

    assert_empty ops.read
  end

  def test_extract_ignores_an_empty_path
    ops = Compaction.create_file_ops
    message = assistant_with(call("read", { "path" => "" }))

    Compaction.extract_file_ops_from_message(message, ops)

    assert_empty ops.read
  end

  def test_extract_deduplicates_repeated_paths_across_messages
    ops = Compaction.create_file_ops
    read_a = assistant_with(call("read", { "path" => "a.rb" }))
    Compaction.extract_file_ops_from_message(read_a, ops)
    Compaction.extract_file_ops_from_message(read_a, ops)

    assert_equal Set["a.rb"], ops.read
  end

  def test_compute_file_lists_sorts_and_splits_read_only_from_modified
    ops = Compaction.create_file_ops
    ops.read.merge(%w[z.rb a.rb])
    ops.written << "w.rb"
    ops.edited << "e.rb"

    lists = Compaction.compute_file_lists(ops)

    assert_equal %w[a.rb z.rb], lists[:read_files]
    assert_equal %w[e.rb w.rb], lists[:modified_files]
  end

  def test_compute_file_lists_treats_a_read_then_modified_file_as_modified_only
    ops = Compaction.create_file_ops
    ops.read << "shared.rb"
    ops.edited << "shared.rb"

    lists = Compaction.compute_file_lists(ops)

    assert_empty lists[:read_files]
    assert_equal %w[shared.rb], lists[:modified_files]
  end

  def test_format_file_operations_renders_both_sections_with_a_leading_blank_line
    text = Compaction.format_file_operations(%w[r1.rb r2.rb], %w[m1.rb])

    expected = "\n\n<read-files>\nr1.rb\nr2.rb\n</read-files>\n\n" \
               "<modified-files>\nm1.rb\n</modified-files>"

    assert_equal expected, text
  end

  def test_format_file_operations_omits_an_empty_section
    assert_equal "\n\n<read-files>\nr.rb\n</read-files>",
                 Compaction.format_file_operations(%w[r.rb], [])
    assert_equal "\n\n<modified-files>\nm.rb\n</modified-files>",
                 Compaction.format_file_operations([], %w[m.rb])
  end

  def test_format_file_operations_is_empty_when_nothing_touched
    assert_equal "", Compaction.format_file_operations([], [])
  end
end
