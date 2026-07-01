# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require_relative "config"

module Truffle
  # One-time, idempotent migrations for project-local `.truffle/` state.
  #
  # This mirrors pi's startup migration shape: each migration is small,
  # non-destructive, skips files it cannot safely understand, and reports what
  # happened so the CLI can show a useful status.
  module Migrations
    PROJECT_SETTINGS_VERSION = 1

    Result = Struct.new(:applied, :warnings, keyword_init: true) do
      def changed? = !applied.empty?
    end

    module_function

    def run(cwd: Dir.pwd, agent_dir: Config.agent_dir)
      result = Result.new(applied: [], warnings: [])
      migrate_project_settings(cwd: cwd, result: result)
      migrate_root_sessions(agent_dir: agent_dir, result: result)
      result
    end

    def run_project(cwd: Dir.pwd)
      result = Result.new(applied: [], warnings: [])
      migrate_project_settings(cwd: cwd, result: result)
      result
    end

    def run_agent(agent_dir: Config.agent_dir)
      result = Result.new(applied: [], warnings: [])
      migrate_root_sessions(agent_dir: agent_dir, result: result)
      result
    end

    def migrate_project_settings(cwd:, result:)
      path = Config.project_settings_path(cwd: cwd)
      return unless File.file?(path)

      settings = JSON.parse(File.read(path, encoding: "UTF-8"))
      unless settings.is_a?(Hash)
        result.warnings << "#{path} must contain a JSON object; left unchanged"
        return
      end

      version = settings.key?("version") ? integer_version(settings["version"]) : 0
      if version.nil?
        result.warnings << "#{path} has a non-integer version; left unchanged"
        return
      end

      if version > PROJECT_SETTINGS_VERSION
        result.warnings << "#{path} is version #{version}, newer than this " \
                           "Truffle supports; left unchanged"
        return
      end

      return if version == PROJECT_SETTINGS_VERSION

      settings["version"] = PROJECT_SETTINGS_VERSION
      write_json(path, settings)
      result.applied << path
    rescue JSON::ParserError, SystemCallError => e
      result.warnings << "could not migrate #{path}: #{e.message}"
    end
    private_class_method :migrate_project_settings

    def migrate_root_sessions(agent_dir:, result:)
      root_files(agent_dir).each do |path|
        header = read_session_header(path)
        next unless header

        target_dir = Config.default_session_dir(cwd: header.fetch("cwd"), agent_dir: agent_dir)
        target_path = File.join(target_dir, File.basename(path))
        next if File.exist?(target_path)

        FileUtils.mkdir_p(target_dir)
        File.rename(path, target_path)
        result.applied << target_path
      rescue SystemCallError
        next
      end
    end
    private_class_method :migrate_root_sessions

    def root_files(agent_dir)
      Dir.children(agent_dir)
         .select { |entry| entry.end_with?(".jsonl") }
         .map { |entry| File.join(agent_dir, entry) }
    rescue SystemCallError
      []
    end
    private_class_method :root_files

    def read_session_header(path)
      line = File.open(path, &:gets)
      return nil if line.to_s.strip.empty?

      header = JSON.parse(line)
      return nil unless header.is_a?(Hash)
      return nil unless header["type"] == "session"

      cwd = header["cwd"]
      return nil unless cwd.is_a?(String) && !cwd.empty?

      header
    rescue JSON::ParserError, SystemCallError
      nil
    end
    private_class_method :read_session_header

    def integer_version(value)
      Integer(value, exception: false)
    end
    private_class_method :integer_version

    def write_json(path, value)
      dir = File.dirname(path)
      basename = File.basename(path)
      mode = File.stat(path).mode & 0o777
      tmp_path = File.join(dir, ".#{basename}.#{Process.pid}.#{SecureRandom.hex(8)}.tmp")

      File.open(tmp_path, File::WRONLY | File::CREAT | File::EXCL, mode) do |handle|
        handle.write("#{JSON.pretty_generate(value)}\n")
        handle.flush
        handle.fsync
      end
      File.chmod(mode, tmp_path)
      File.rename(tmp_path, path)
    ensure
      FileUtils.rm_f(tmp_path) if tmp_path && File.exist?(tmp_path)
    end
    private_class_method :write_json
  end
end
