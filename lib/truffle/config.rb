# frozen_string_literal: true

module Truffle
  # Filesystem locations for Truffle's local configuration. This is the Ruby
  # counterpart of pi's CONFIG_DIR_NAME/getAgentDir helpers, narrowed to the path
  # pieces this port currently uses. The project directory is `.truffle/`; the
  # user agent directory defaults to `~/.truffle/agent` and can be overridden with
  # TRUFFLE_AGENT_DIR.
  module Config
    CONFIG_DIR_NAME = ".truffle"
    ENV_AGENT_DIR = "TRUFFLE_AGENT_DIR"

    module_function

    def agent_dir(home: Dir.home, env: ENV)
      configured = env[ENV_AGENT_DIR].to_s
      return File.expand_path(configured) unless configured.empty?

      File.join(home, CONFIG_DIR_NAME, "agent")
    end

    def project_dir(cwd: Dir.pwd)
      File.join(File.expand_path(cwd), CONFIG_DIR_NAME)
    end

    def prompts_dir(agent_dir: self.agent_dir)
      File.join(File.expand_path(agent_dir), "prompts")
    end

    def project_prompts_dir(cwd: Dir.pwd)
      File.join(project_dir(cwd: cwd), "prompts")
    end

    def project_settings_path(cwd: Dir.pwd)
      File.join(project_dir(cwd: cwd), "settings.json")
    end

    # The agent-level directory that holds one session subdirectory per project.
    def sessions_dir(agent_dir: self.agent_dir)
      File.join(File.expand_path(agent_dir), "sessions")
    end

    # The default session directory for a working directory, matching pi's
    # getDefaultSessionDirPath: the cwd is encoded into a single path-safe segment
    # by stripping its leading separator and folding `/`, `\`, and `:` to `-`, then
    # wrapped in `--...--` so two projects never share a session directory.
    def default_session_dir(cwd: Dir.pwd, agent_dir: self.agent_dir)
      encoded = File.expand_path(cwd).sub(%r{\A[/\\]}, "").gsub(%r{[/\\:]}, "-")
      File.join(sessions_dir(agent_dir: agent_dir), "--#{encoded}--")
    end
  end
end
