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
end
