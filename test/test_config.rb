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
      assert_equal File.join(cwd, ".truffle", "settings.json"),
                   Config.project_settings_path(cwd: cwd)
      assert_equal File.join(cwd, ".truffle", "agent", "prompts"),
                   Config.prompts_dir(agent_dir: File.join(cwd, ".truffle", "agent"))
    end
  end

  def test_sessions_dir_lives_under_the_agent_dir
    assert_equal File.join("/agent", "sessions"), Config.sessions_dir(agent_dir: "/agent")
  end

  def test_default_session_dir_encodes_the_cwd_into_one_safe_segment
    # The leading slash is stripped and every remaining separator folds to a dash,
    # so an absolute cwd becomes a single `--...--` directory name.
    assert_equal File.join("/agent", "sessions", "--home-ada-my-project--"),
                 Config.default_session_dir(cwd: "/home/ada/my/project", agent_dir: "/agent")
  end

  def test_default_session_dir_keeps_two_projects_apart
    first = Config.default_session_dir(cwd: "/home/ada/one", agent_dir: "/agent")
    second = Config.default_session_dir(cwd: "/home/ada/two", agent_dir: "/agent")

    assert_equal File.join("/agent", "sessions", "--home-ada-one--"), first
    refute_equal first, second
  end

  def test_default_session_dir_folds_a_colon_in_the_path
    # Each of `:` and `/` folds independently, so an adjacent colon-slash becomes
    # a double dash, matching pi's per-character replace.
    assert_equal File.join("/agent", "sessions", "--C--work-repo--"),
                 Config.default_session_dir(cwd: "/C:/work/repo", agent_dir: "/agent")
  end
end
