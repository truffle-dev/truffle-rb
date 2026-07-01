# frozen_string_literal: true

require "fileutils"
require "json"

module Truffle
  module CLI
    # Non-destructive project scaffolding for `truffle init`. This is the first
    # project-config slice: it creates the local Truffle directory and a project
    # memory file without teaching the runtime new settings semantics yet.
    module Init
      Result = Struct.new(:created, :existing, keyword_init: true)

      SETTINGS = { "version" => 1 }.freeze
      MEMORY_TEMPLATE = <<~MARKDOWN
        # Project Instructions

        Add project-specific guidance for Truffle agents here. Keep it short and
        actionable.

        - Build/test commands:
        - Important paths:
        - Constraints:
      MARKDOWN

      module_function

      def project(cwd: Dir.pwd)
        root = File.expand_path(cwd)
        created = []
        existing = []

        ensure_dir(Config.project_dir(cwd: root), created, existing)
        %w[prompts extensions skills sessions].each do |name|
          ensure_dir(File.join(Config.project_dir(cwd: root), name), created, existing)
        end
        ensure_json(File.join(Config.project_dir(cwd: root), "settings.json"), SETTINGS,
                    created, existing)
        ensure_file(File.join(root, "AGENTS.md"), MEMORY_TEMPLATE, created, existing)

        Result.new(created: relative_paths(created, root), existing: relative_paths(existing, root))
      end

      def ensure_dir(path, created, existing)
        if File.directory?(path)
          existing << path
        else
          FileUtils.mkdir_p(path)
          created << path
        end
      end
      private_class_method :ensure_dir

      def ensure_file(path, content, created, existing)
        if File.exist?(path)
          existing << path
        else
          File.write(path, content)
          created << path
        end
      end
      private_class_method :ensure_file

      def ensure_json(path, value, created, existing)
        ensure_file(path, "#{JSON.pretty_generate(value)}\n", created, existing)
      end
      private_class_method :ensure_json

      def relative_paths(paths, root)
        paths.map do |path|
          relative = path.delete_prefix("#{root}/")
          File.directory?(path) ? "#{relative}/" : relative
        end
      end
      private_class_method :relative_paths
    end
  end
end
