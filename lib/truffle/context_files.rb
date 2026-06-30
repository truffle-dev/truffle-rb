# frozen_string_literal: true

require_relative "tools/path"

module Truffle
  # Discovery of project instruction files, the Ruby port of pi's
  # `loadProjectContextFiles` (`core/resource-loader.ts`). These are the
  # AGENTS.md / CLAUDE.md files a project (and the user's global agent directory)
  # carry to steer the agent; `Truffle::SystemPrompt.build` folds them into its
  # `<project_context>` block, so `load` returns the same `{ path:, content: }`
  # shape that builder consumes.
  #
  # The order is meaningful: the global agent-directory file comes first, then the
  # chain from the filesystem root down to the working directory, so the nearest
  # (most specific) file lands last and a downstream consumer that lets later
  # instructions win honors the closer file. A single file reachable by more than
  # one route (the agent dir is also an ancestor of cwd) appears once.
  module ContextFiles
    # The instruction-file names pi looks for, in precedence order within one
    # directory: the first that exists wins, matching pi's candidate list.
    CANDIDATES = ["AGENTS.md", "AGENTS.MD", "CLAUDE.md", "CLAUDE.MD"].freeze

    module_function

    # Collect the project context files for a working directory and a global agent
    # directory. Both are resolved to absolute paths through the same path logic pi
    # shares between its tools and this loader. `warn` receives a message for an
    # unreadable candidate; it defaults to writing to standard error, the way pi
    # logs the warning, and is injectable so tests stay quiet and deterministic.
    def load(cwd:, agent_dir:, warn: method(:default_warn))
      resolved_cwd = Tools::Path.resolve(cwd, Dir.pwd)
      resolved_agent_dir = Tools::Path.resolve(agent_dir, Dir.pwd)

      context_files = []
      seen = {}

      global = load_from_dir(resolved_agent_dir, warn)
      if global
        context_files << global
        seen[global[:path]] = true
      end

      ancestors = []
      current = resolved_cwd
      root = File.expand_path("/")
      loop do
        file = load_from_dir(current, warn)
        if file && !seen[file[:path]]
          ancestors.unshift(file)
          seen[file[:path]] = true
        end

        break if current == root

        parent = File.expand_path("..", current)
        break if parent == current

        current = parent
      end

      context_files.concat(ancestors)
      context_files
    end

    # The first existing instruction file in a directory as a `{ path:, content: }`
    # hash, or nil when none is present. An unreadable candidate warns and falls
    # through to the next name, mirroring pi reading inside the candidate loop.
    def load_from_dir(dir, warn)
      CANDIDATES.each do |name|
        path = File.join(dir, name)
        next unless File.exist?(path)

        begin
          return { path: path, content: File.read(path) }
        rescue StandardError => e
          warn.call("Could not read #{path}: #{e.message}")
        end
      end
      nil
    end

    def default_warn(message)
      warn("Warning: #{message}")
    end
    private_class_method :load_from_dir, :default_warn
  end
end
