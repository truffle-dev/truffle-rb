# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

# The write built-in tool, ported from pi's write.ts. Files are written into a
# temp dir so the suite stays hermetic.
class TestToolsWrite < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("truffle-write")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def write_tool
    Truffle::Tools.write(cwd: @dir)
  end

  def read_back(name)
    File.read(File.join(@dir, name))
  end

  def test_schema_advertises_path_and_content_required
    schema = write_tool.to_schema

    assert_equal "write", schema[:name]
    assert_equal %w[path content], schema[:parameters][:required]
    props = schema[:parameters][:properties]

    assert_equal "string", props["path"][:type]
    assert_equal "string", props["content"][:type]
  end

  def test_creates_new_file_relative_to_cwd
    out = write_tool.call("path" => "new.txt", "content" => "hello\nworld\n")

    assert_equal "hello\nworld\n", read_back("new.txt")
    assert_equal "Successfully wrote 12 bytes to new.txt", out
  end

  def test_overwrites_existing_file
    File.write(File.join(@dir, "exists.txt"), "old content here")

    out = write_tool.call("path" => "exists.txt", "content" => "new")

    assert_equal "new", read_back("exists.txt")
    assert_equal "Successfully wrote 3 bytes to exists.txt", out
  end

  def test_creates_nested_parent_directories
    write_tool.call("path" => "a/b/c/deep.txt", "content" => "nested")

    assert_equal "nested", read_back("a/b/c/deep.txt")
  end

  def test_writes_to_absolute_path
    target = File.join(@dir, "abs.txt")

    out = write_tool.call("path" => target, "content" => "abs body")

    assert_equal "abs body", File.read(target)
    assert_equal "Successfully wrote 8 bytes to #{target}", out
  end

  def test_byte_count_uses_bytesize_not_char_length
    # "café" is 4 characters but 5 UTF-8 bytes (é is two bytes). pi labels the
    # count "bytes" while measuring content.length (4 here); we report the real
    # byte count, so the message must say 5, not 4.
    out = write_tool.call("path" => "uni.txt", "content" => "café")

    assert_equal "café", read_back("uni.txt")
    assert_equal "Successfully wrote 5 bytes to uni.txt", out
  end

  def test_path_unicode_space_is_folded
    # A no-break space (U+00A0) in the path folds to a plain space before
    # resolution, so the file lands under a regular-space directory name.
    write_tool.call("path" => "sub\u00A0dir/f.txt", "content" => "x")

    assert_path_exists File.join(@dir, "sub dir", "f.txt")
  end

  def test_leading_at_prefix_is_stripped_from_path
    # A single leading "@" is stripped (pi's @file convention), so "@out.txt"
    # writes to "out.txt". The confirmation still echoes the path as passed.
    out = write_tool.call("path" => "@out.txt", "content" => "y")

    assert_path_exists File.join(@dir, "out.txt")
    assert_equal "Successfully wrote 1 bytes to @out.txt", out
  end
end
