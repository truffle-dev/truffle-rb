# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

# Built-in tool execution modes are part of the safety contract. The agent loop
# already runs a whole batch sequentially when any requested tool is sequential;
# mutating built-ins must opt into that guard.
class TestBuiltinToolExecutionModes < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("truffle-tool-modes")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_mutating_tools_are_sequential
    assert_equal :sequential, Truffle::Tools.write(cwd: @dir).execution_mode
    assert_equal :sequential, Truffle::Tools.edit(cwd: @dir).execution_mode
    assert_equal :sequential, Truffle::Tools.bash(cwd: @dir).execution_mode
  end

  def test_read_only_tools_stay_parallel
    assert_equal :parallel, Truffle::Tools.read(cwd: @dir).execution_mode
    assert_equal :parallel, Truffle::Tools.find(cwd: @dir).execution_mode
    assert_equal :parallel, Truffle::Tools.grep(cwd: @dir).execution_mode
  end
end
