# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# Project context-file discovery, a port of pi's loadProjectContextFiles
# (core/resource-loader.ts). Each test builds a real directory tree under a
# tmpdir so the walk, the candidate precedence, the dedup, and the ordering are
# exercised against the filesystem the way the loader runs in production.
class TestContextFiles < Minitest::Test
  def write_file(dir, name, content)
    path = File.join(dir, name)
    File.write(path, content)
    path
  end

  def test_returns_empty_when_no_instruction_files_exist
    Dir.mktmpdir do |root|
      cwd = File.join(root, "project")
      agent = File.join(root, "agent")
      Dir.mkdir(cwd)
      Dir.mkdir(agent)

      assert_empty Truffle::ContextFiles.load(cwd: cwd, agent_dir: agent)
    end
  end

  def test_loads_a_single_cwd_file_with_path_and_content
    Dir.mktmpdir do |root|
      agent = File.join(root, "agent")
      Dir.mkdir(agent)
      path = write_file(root, "AGENTS.md", "house rules")

      result = Truffle::ContextFiles.load(cwd: root, agent_dir: agent)

      assert_equal [{ path: path, content: "house rules" }], result
    end
  end

  def test_agents_md_wins_over_claude_md_in_the_same_directory
    Dir.mktmpdir do |root|
      agent = File.join(root, "agent")
      Dir.mkdir(agent)
      agents = write_file(root, "AGENTS.md", "from agents")
      write_file(root, "CLAUDE.md", "from claude")

      result = Truffle::ContextFiles.load(cwd: root, agent_dir: agent)

      assert_equal [{ path: agents, content: "from agents" }], result
    end
  end

  def test_global_agent_file_comes_first_then_the_project_file
    Dir.mktmpdir do |root|
      agent = File.join(root, "agent")
      cwd = File.join(root, "project")
      Dir.mkdir(agent)
      Dir.mkdir(cwd)
      global = write_file(agent, "AGENTS.md", "global")
      local = write_file(cwd, "AGENTS.md", "local")

      result = Truffle::ContextFiles.load(cwd: cwd, agent_dir: agent)

      assert_equal(
        [{ path: global, content: "global" }, { path: local, content: "local" }],
        result
      )
    end
  end

  def test_ancestors_are_ordered_outermost_first_with_cwd_last
    Dir.mktmpdir do |root|
      agent = File.join(root, "agent")
      Dir.mkdir(agent)
      parent = File.join(root, "parent")
      child = File.join(parent, "child")
      Dir.mkdir(parent)
      Dir.mkdir(child)
      parent_file = write_file(parent, "AGENTS.md", "parent")
      child_file = write_file(child, "AGENTS.md", "child")

      result = Truffle::ContextFiles.load(cwd: child, agent_dir: agent)

      assert_equal([parent_file, child_file], result.map { |f| f[:path] })
    end
  end

  def test_a_file_reachable_as_both_agent_dir_and_ancestor_appears_once
    Dir.mktmpdir do |root|
      # The agent dir is also the cwd, so its file is discovered twice; the
      # seen-path guard keeps it to a single entry.
      file = write_file(root, "AGENTS.md", "shared")

      result = Truffle::ContextFiles.load(cwd: root, agent_dir: root)

      assert_equal [{ path: file, content: "shared" }], result
    end
  end

  def test_an_unreadable_candidate_warns_and_falls_through_to_the_next
    Dir.mktmpdir do |root|
      agent = File.join(root, "agent")
      Dir.mkdir(agent)
      # AGENTS.md is a directory, so File.read raises; the loader should warn and
      # fall through to CLAUDE.md rather than abort.
      Dir.mkdir(File.join(root, "AGENTS.md"))
      claude = write_file(root, "CLAUDE.md", "fallback")

      warnings = []
      result = Truffle::ContextFiles.load(
        cwd: root, agent_dir: agent, warn: ->(message) { warnings << message }
      )

      assert_equal [{ path: claude, content: "fallback" }], result
      assert_equal 1, warnings.length
      assert_includes warnings.first, "AGENTS.md"
    end
  end
end
