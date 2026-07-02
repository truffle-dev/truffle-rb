# frozen_string_literal: true

require "json"
require "fileutils"

module Truffle
  # Project trust, ported from pi's trust-manager.ts. A working directory is
  # "trusted" when the user has allowed Truffle to load its `.truffle` settings
  # and resources, install project packages, and run its extensions. The trust
  # decision for a directory (or a nearest trusted ancestor) is persisted in a
  # `trust.json` file under the agent directory.
  #
  # This is the storage and detection half. The orchestration that fires
  # extension events, reads the `defaultProjectTrust` setting, and prompts the
  # user (pi's resolveProjectTrusted in project-trust.ts) belongs to the session
  # and extensions layer and is a separate slice.
  #
  # pi serializes concurrent writers with the proper-lockfile npm package. This
  # port uses an advisory `File#flock` on a `trust.json.lock` sidecar instead, so
  # it adds no runtime dependency.
  module ProjectTrust
    # Project-local resources under `cwd/.truffle` whose presence means the
    # directory must be gated by trust before they are loaded.
    TRUST_REQUIRING_RESOURCES = %w[
      settings.json
      extensions
      skills
      prompts
      themes
      SYSTEM.md
      APPEND_SYSTEM.md
    ].freeze

    # A stored decision resolved for a directory: the path that carried it and the
    # boolean decision itself.
    StoreEntry = Struct.new(:path, :decision)

    # One change to apply to the store. A nil decision removes the path's entry.
    Update = Struct.new(:path, :decision)

    # A trust choice a UI can present: its label, the resulting trust boolean, the
    # store updates it applies, and the path it saves against (nil for a
    # session-only choice that persists nothing).
    Option = Struct.new(:label, :trusted, :updates, :saved_path)

    module_function

    # The canonical parent of cwd, or nil when cwd is already the filesystem root.
    # Port of pi's getProjectTrustParentPath.
    def parent_path(cwd)
      trust_path = normalize_cwd(cwd)
      parent = File.dirname(trust_path)
      parent == trust_path ? nil : parent
    end

    # The trust choices for cwd. Always offers "Trust" and "Do not trust" for the
    # directory itself, offers trusting the parent folder when one exists, and,
    # when include_session_only is set, the two choices that apply for this
    # session without persisting. Port of pi's getProjectTrustOptions.
    def options(cwd, include_session_only: false)
      trust_path = normalize_cwd(cwd)
      choices = [Option.new("Trust", true, [Update.new(trust_path, true)], trust_path)]

      parent = parent_path(cwd)
      unless parent.nil?
        choices << Option.new(
          "Trust parent folder (#{parent})", true,
          [Update.new(parent, true), Update.new(trust_path, nil)], parent
        )
      end

      choices << Option.new("Trust (this session only)", true, [], nil) if include_session_only
      choices << Option.new("Do not trust", false, [Update.new(trust_path, false)], trust_path)
      if include_session_only
        choices << Option.new("Do not trust (this session only)", false, [], nil)
      end
      choices
    end

    # True when cwd has project-local resources that must be gated by trust:
    # trust-requiring entries under `cwd/.truffle`, or a `.agents/skills` directory
    # in cwd or one of its ancestors. The user-level `~/.agents/skills` is always
    # treated as a trusted user resource and is ignored, even when cwd is $HOME.
    # Port of pi's hasTrustRequiringProjectResources.
    def trust_requiring_resources?(cwd, env: ENV, home: env["HOME"] || Dir.home)
      user_skills = File.join(normalize_cwd(home), ".agents", "skills")
      current = normalize_cwd(cwd)

      config_dir = File.join(current, Config::CONFIG_DIR_NAME)
      config_resource = TRUST_REQUIRING_RESOURCES.any? do |entry|
        File.exist?(File.join(config_dir, entry))
      end
      return true if config_resource

      loop do
        skills_dir = File.join(current, ".agents", "skills")
        return true if skills_dir != user_skills && File.exist?(skills_dir)

        parent = File.dirname(current)
        return false if parent == current

        current = parent
      end
    end

    # canonicalizePath(resolvePath(cwd)): absolute, symlinks resolved when the path
    # exists, otherwise the absolute path unchanged.
    def normalize_cwd(cwd)
      Paths.canonicalize(File.expand_path(cwd))
    end

    # Walk from cwd toward the root, returning the first ancestor with a true or
    # false decision, or nil when none is recorded. A stored nil means "no
    # decision here, keep walking". Port of pi's findNearestTrustEntry.
    def nearest_entry(data, cwd)
      current = normalize_cwd(cwd)
      loop do
        value = data[current]
        return StoreEntry.new(current, value) if [true, false].include?(value)

        parent = File.dirname(current)
        return nil if parent == current

        current = parent
      end
    end

    # The persistent store of trust decisions, keyed by canonical path, backed by
    # `trust.json` in the agent directory. Port of pi's ProjectTrustStore.
    class Store
      def initialize(agent_dir)
        @trust_path = File.join(File.expand_path(agent_dir), "trust.json")
      end

      # The trust decision that applies to cwd (its own or the nearest trusted
      # ancestor's), or nil when none is recorded.
      def get(cwd)
        entry(cwd)&.decision
      end

      def entry(cwd)
        with_lock { ProjectTrust.nearest_entry(read_file, cwd) }
      end

      def set(cwd, decision)
        set_many([Update.new(cwd, decision)])
      end

      # Apply a batch of updates atomically under the file lock. A nil decision
      # removes the entry; a boolean records it against the canonical path.
      def set_many(updates) # rubocop:disable Naming/AccessorMethodName
        with_lock do
          data = read_file
          updates.each do |update|
            key = ProjectTrust.normalize_cwd(update.path)
            if update.decision.nil?
              data.delete(key)
            else
              data[key] = update.decision
            end
          end
          write_file(data)
        end
      end

      private

      def read_file
        return {} unless File.exist?(@trust_path)

        parsed = parse_trust_file
        unless parsed.is_a?(Hash)
          raise Error, "Invalid trust store #{@trust_path}: expected an object"
        end

        parsed.each_with_object({}) do |(key, value), data|
          unless value == true || value == false || value.nil?
            raise Error, "Invalid trust store #{@trust_path}: value for " \
                         "#{key.inspect} must be true, false, or null"
          end
          data[key] = value
        end
      end

      def parse_trust_file
        JSON.parse(File.read(@trust_path))
      rescue JSON::ParserError => e
        raise Error, "Failed to read trust store #{@trust_path}: #{e.message}"
      end

      def write_file(data)
        sorted = data.keys.sort.each_with_object({}) do |key, acc|
          value = data[key]
          acc[key] = value if value == true || value == false || value.nil?
        end
        FileUtils.mkdir_p(File.dirname(@trust_path))
        File.write(@trust_path, "#{JSON.pretty_generate(sorted)}\n")
      end

      def with_lock
        FileUtils.mkdir_p(File.dirname(@trust_path))
        File.open("#{@trust_path}.lock", File::RDWR | File::CREAT, 0o644) do |lock|
          lock.flock(File::LOCK_EX)
          begin
            yield
          ensure
            lock.flock(File::LOCK_UN)
          end
        end
      end
    end
  end
end
