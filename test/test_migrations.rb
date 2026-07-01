# frozen_string_literal: true

require "test_helper"
require "json"
require "tmpdir"
require "fileutils"

class TestMigrations < Minitest::Test
  def write_settings(dir, content)
    FileUtils.mkdir_p(File.join(dir, ".truffle"))
    File.write(File.join(dir, ".truffle", "settings.json"), content)
  end

  def read_settings(dir)
    JSON.parse(File.read(File.join(dir, ".truffle", "settings.json")))
  end

  def write_session(path, cwd:, id: "sess-1")
    header = { type: "session", version: Truffle::Session::SESSION_VERSION,
               id: id, timestamp: "2026-01-01T00:00:00.000Z", cwd: cwd }
    File.write(path, "#{JSON.generate(header)}\n")
  end

  def test_missing_project_settings_has_no_work
    Dir.mktmpdir("truffle-migrations") do |dir|
      result = Truffle::Migrations.run_project(cwd: dir)

      assert_empty result.applied
      assert_empty result.warnings
      refute_predicate result, :changed?
    end
  end

  def test_unversioned_project_settings_are_stamped
    Dir.mktmpdir("truffle-migrations") do |dir|
      write_settings(dir, "#{JSON.pretty_generate({ "defaultProvider" => "openai" })}\n")

      result = Truffle::Migrations.run_project(cwd: dir)

      assert_equal [File.join(dir, ".truffle", "settings.json")], result.applied
      assert_empty result.warnings
      assert_predicate result, :changed?
      assert_equal({ "defaultProvider" => "openai", "version" => 1 }, read_settings(dir))
    end
  end

  def test_current_project_settings_are_left_unchanged
    Dir.mktmpdir("truffle-migrations") do |dir|
      write_settings(dir, "#{JSON.pretty_generate({ "version" => 1 })}\n")

      result = Truffle::Migrations.run_project(cwd: dir)

      assert_empty result.applied
      assert_empty result.warnings
      assert_equal({ "version" => 1 }, read_settings(dir))
    end
  end

  def test_newer_project_settings_are_left_unchanged_with_a_warning
    Dir.mktmpdir("truffle-migrations") do |dir|
      write_settings(dir, "#{JSON.pretty_generate({ "version" => 99 })}\n")

      result = Truffle::Migrations.run_project(cwd: dir)

      assert_empty result.applied
      assert_equal 1, result.warnings.length
      assert_includes result.warnings.first, "newer than this Truffle supports"
      assert_equal({ "version" => 99 }, read_settings(dir))
    end
  end

  def test_malformed_project_settings_are_left_unchanged_with_a_warning
    Dir.mktmpdir("truffle-migrations") do |dir|
      write_settings(dir, "{")

      result = Truffle::Migrations.run_project(cwd: dir)

      assert_empty result.applied
      assert_equal 1, result.warnings.length
      assert_includes result.warnings.first, "could not migrate"
      assert_equal "{", File.read(File.join(dir, ".truffle", "settings.json"))
    end
  end

  def test_missing_agent_dir_has_no_work
    Dir.mktmpdir("truffle-migrations") do |dir|
      result = Truffle::Migrations.run_agent(agent_dir: File.join(dir, "missing"))

      assert_empty result.applied
      assert_empty result.warnings
    end
  end

  def test_root_session_files_move_to_their_project_directory
    Dir.mktmpdir("truffle-migrations") do |dir|
      agent_dir = File.join(dir, "agent")
      project_dir = File.join(dir, "app")
      FileUtils.mkdir_p(agent_dir)
      FileUtils.mkdir_p(project_dir)
      source = File.join(agent_dir, "session.jsonl")
      write_session(source, cwd: project_dir)

      result = Truffle::Migrations.run_agent(agent_dir: agent_dir)

      session_dir = Truffle::Config.default_session_dir(cwd: project_dir, agent_dir: agent_dir)
      target = File.join(session_dir, "session.jsonl")

      assert_equal [target], result.applied
      assert_empty result.warnings
      refute_path_exists source
      assert_path_exists target
    end
  end

  def test_root_session_migration_skips_existing_targets
    Dir.mktmpdir("truffle-migrations") do |dir|
      agent_dir = File.join(dir, "agent")
      project_dir = File.join(dir, "app")
      target_dir = Truffle::Config.default_session_dir(cwd: project_dir, agent_dir: agent_dir)
      FileUtils.mkdir_p([agent_dir, project_dir, target_dir])
      source = File.join(agent_dir, "session.jsonl")
      target = File.join(target_dir, "session.jsonl")
      write_session(source, cwd: project_dir, id: "source")
      write_session(target, cwd: project_dir, id: "target")

      result = Truffle::Migrations.run_agent(agent_dir: agent_dir)

      assert_empty result.applied
      assert_empty result.warnings
      assert_path_exists source
      assert_path_exists target
    end
  end

  def test_root_session_migration_skips_malformed_headers
    Dir.mktmpdir("truffle-migrations") do |dir|
      agent_dir = File.join(dir, "agent")
      FileUtils.mkdir_p(agent_dir)
      malformed = File.join(agent_dir, "bad.jsonl")
      File.write(malformed, "{\n")

      result = Truffle::Migrations.run_agent(agent_dir: agent_dir)

      assert_empty result.applied
      assert_empty result.warnings
      assert_path_exists malformed
    end
  end
end
