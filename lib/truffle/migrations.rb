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

    def run_project(cwd: Dir.pwd)
      result = Result.new(applied: [], warnings: [])
      migrate_project_settings(cwd: cwd, result: result)
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
