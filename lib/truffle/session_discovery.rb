# frozen_string_literal: true

module Truffle
  class Session
    # List sessions across all per-project session directories, newest first.
    # Port of pi's SessionManager.listAll, narrowed to the same lightweight
    # header summaries as .list. Passing dir: lists that custom session directory
    # only; otherwise every child directory under Config.sessions_dir is scanned.
    def self.list_all(dir: nil, agent_dir: Config.agent_dir)
      directories =
        if dir
          [File.expand_path(dir)]
        else
          session_directories(agent_dir)
        end

      directories.flat_map { |directory| list(dir: directory) }
                 .sort_by { |summary| [summary.mtime, summary.path] }
                 .reverse
    rescue SystemCallError
      []
    end

    def self.session_directories(agent_dir)
      root = Config.sessions_dir(agent_dir: agent_dir)
      Dir.children(root)
         .map { |name| File.join(root, name) }
         .select { |path| File.directory?(path) }
    end
    private_class_method :session_directories
  end
end
