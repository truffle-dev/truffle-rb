# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class TestConfig < Minitest::Test
  Config = Truffle::Config

  def test_default_agent_dir_lives_under_home_truffle_agent
    Dir.mktmpdir("truffle-home") do |home|
      assert_equal File.join(home, ".truffle", "agent"), Config.agent_dir(home: home, env: {})
    end
  end

  def test_agent_dir_can_be_overridden_by_environment
    Dir.mktmpdir("truffle-agent") do |agent_dir|
      env = { "TRUFFLE_AGENT_DIR" => agent_dir }

      assert_equal File.expand_path(agent_dir), Config.agent_dir(env: env)
    end
  end

  def test_project_and_prompt_directories
    Dir.mktmpdir("truffle-project") do |cwd|
      assert_equal File.join(cwd, ".truffle"), Config.project_dir(cwd: cwd)
      assert_equal File.join(cwd, ".truffle", "prompts"), Config.project_prompts_dir(cwd: cwd)
      assert_equal File.join(cwd, ".truffle", "agent", "prompts"),
                   Config.prompts_dir(agent_dir: File.join(cwd, ".truffle", "agent"))
    end
  end
end
