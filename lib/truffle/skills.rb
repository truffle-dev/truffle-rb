# frozen_string_literal: true

require "yaml"

module Truffle
  # Skills, ported from pi's skills.ts. A skill is a markdown file (a SKILL.md in
  # its own folder, or a plain .md) whose frontmatter names it and describes when
  # to use it; its body is instructions the model reads on demand. The loader
  # parses one file into a Skill (or a diagnostic when it is malformed), validates
  # the name and description against the Agent Skills spec, and formats a set of
  # skills into the <available_skills> block a system prompt advertises.
  #
  # This first slice covers single-file loading, validation, and prompt
  # formatting. Directory discovery (SKILL.md-root vs .md-children vs recurse),
  # name-collision resolution across user/project/path sources, and the
  # gitignore-style ignore matching pi layers on top are faithful follow-ups; the
  # ignore matching in particular needs a matcher pi gets from the `ignore` npm
  # package, which a zero-dependency port must hand-roll in its own slice. pi's
  # SourceInfo (a TUI/diagnostics affordance) is not ported.
  module Skills
    # Per the Agent Skills spec: a name is at most 64 characters and a description
    # at most 1024.
    MAX_NAME_LENGTH = 64
    MAX_DESCRIPTION_LENGTH = 1024

    # A loaded skill: its spec name, the description the model matches against, the
    # file it was read from, the directory relative paths in its body resolve
    # against, and whether the model may invoke it implicitly (false hides it from
    # the prompt so it is only reachable by an explicit command). Ports pi's Skill.
    Skill = Struct.new(:name, :description, :file_path, :base_dir, :disable_model_invocation,
                       keyword_init: true)

    # A problem found while loading: a type ("warning" or "collision"), a human
    # message, the path it concerns, and (for a collision) the detail of which
    # skill won and which lost. Ports the warning and collision shapes of pi's
    # ResourceDiagnostic; the "error" type and pi's source-scoped fields are not
    # ported. The :collision member is nil for an ordinary warning.
    Diagnostic = Struct.new(:type, :message, :path, :collision, keyword_init: true)

    # The detail carried by a collision diagnostic: the resource kind (always
    # "skill" here), the colliding name, and the winning and losing file paths.
    # Ports pi's ResourceCollision minus its optional source fields.
    Collision = Struct.new(:resource_type, :name, :winner_path, :loser_path, keyword_init: true)

    module_function

    # Load one markdown file into a Skill plus any diagnostics. The name comes from
    # the frontmatter, falling back to the parent directory's name (so a
    # foo/SKILL.md with no name becomes "foo"). A missing or blank description is
    # fatal (the skill is dropped) since the model has nothing to match on; other
    # validation problems are warnings that still load the skill. A file that
    # cannot be read or parsed yields a single warning and no skill. Ports pi's
    # loadSkillFromFile.
    def load_file(file_path)
      raw = File.read(file_path)
      frontmatter, = Frontmatter.parse(raw)

      description = frontmatter["description"]
      name = string_or_nil(frontmatter["name"]) || File.basename(File.dirname(file_path))
      diagnostics = warnings(validate_description(description), file_path) +
                    warnings(validate_name(name), file_path)

      return [nil, diagnostics] if blank?(description)

      [build_skill(name, description, file_path, frontmatter), diagnostics]
    rescue StandardError => e
      [nil, [Diagnostic.new(type: "warning", message: e.message, path: file_path)]]
    end

    # Discover and load every skill under a directory, returning the skills and
    # the diagnostics gathered along the way. The discovery rules port pi's
    # loadSkillsFromDir: a directory that holds a SKILL.md is a skill root, loaded
    # as one skill with no further recursion; any other directory has its direct
    # .md children loaded and its subdirectories recursed into looking for more
    # SKILL.md roots (a stray .md inside a subdirectory is not a skill, only a
    # SKILL.md is). Dotfiles and node_modules are skipped, and a path that is not a
    # directory yields nothing. Entries are walked in sorted order so the result is
    # deterministic rather than filesystem-order dependent. The ignore-file
    # matching and symlink realpath dedup pi layers on top are deferred to a later
    # slice; ordinary symlinks resolve naturally through File.file?/File.directory?.
    def load_dir(dir)
      load_dir_internal(dir, include_root_files: true)
    end

    # Load skills from a list of explicit paths and merge them into one set,
    # returning the merged skills and the diagnostics gathered. Each path is a
    # markdown file or a directory walked by load_dir; a path that does not exist
    # or is not a markdown file becomes a warning. Two merge rules port pi's
    # loadSkills:
    #
    # - realpath dedup: the same underlying file, reached twice (for instance via
    #   a symlink), is loaded only once. Files are compared by File.realpath so a
    #   symlink and its target count as one.
    # - name collision, first-wins: the first skill seen for a given name wins;
    #   any later skill of that name is dropped and recorded as a "collision"
    #   diagnostic naming the winning and losing files. The dedup check runs
    #   first, so a duplicate file never produces a spurious self-collision.
    #
    # Collision diagnostics are appended after the load warnings, matching pi's
    # ordering. pi's includeDefaults branch (resolving user and project config
    # directories through getAgentDir/CONFIG_DIR_NAME) and its ~ expansion are
    # deferred until the port grows a config subsystem; callers thread the paths
    # in explicitly for now. Ports pi's loadSkills.
    def load_skills(paths)
      skill_map = {}
      real_paths = {}
      warning_diags = []
      collision_diags = []
      paths.each do |path|
        skills, diags = resolve_path_skills(path)
        warning_diags.concat(diags)
        skills.each { |skill| merge_skill(skill, skill_map, real_paths, collision_diags) }
      end
      [skill_map.values, warning_diags + collision_diags]
    end

    # Format skills into the <available_skills> block a system prompt carries,
    # using the XML shape from the Agent Skills standard. Skills with model
    # invocation disabled are left out (they are reachable only by explicit
    # command). An empty visible set produces an empty string. Ports pi's
    # formatSkillsForPrompt.
    def format_for_prompt(skills)
      visible = skills.reject(&:disable_model_invocation)
      return "" if visible.empty?

      lines = [
        "\n\nThe following skills provide specialized instructions for specific tasks.",
        "Use the read tool to load a skill's file when the task matches its description.",
        "When a skill file references a relative path, resolve it against the skill " \
        "directory (parent of SKILL.md / dirname of the path) and use that absolute " \
        "path in tool commands.",
        "",
        "<available_skills>"
      ]
      visible.each do |skill|
        lines << "  <skill>"
        lines << "    <name>#{escape_xml(skill.name)}</name>"
        lines << "    <description>#{escape_xml(skill.description)}</description>"
        lines << "    <location>#{escape_xml(skill.file_path)}</location>"
        lines << "  </skill>"
      end
      lines << "</available_skills>"
      lines.join("\n")
    end

    # The recursive worker behind load_dir. `include_root_files` is true only at
    # the directory the caller named: it gates loading direct .md children, so a
    # bare .md is a skill at a scan root but not when found while recursing for
    # SKILL.md roots. A SKILL.md short-circuits: the directory is one skill and we
    # do not descend. Ports pi's loadSkillsFromDirInternal minus the ignore matcher.
    def load_dir_internal(dir, include_root_files:)
      return [[], []] unless File.directory?(dir)

      entries = Dir.children(dir).sort
      skill_md = File.join(dir, "SKILL.md")
      return load_from(skill_md) if entries.include?("SKILL.md") && File.file?(skill_md)

      skills = []
      diagnostics = []
      entries.each do |name|
        next if name.start_with?(".") || name == "node_modules"

        sub_skills, sub_diags = load_entry(File.join(dir, name), name, include_root_files)
        skills.concat(sub_skills)
        diagnostics.concat(sub_diags)
      end
      [skills, diagnostics]
    end
    private_class_method :load_dir_internal

    # Resolve one directory entry to its skills: descend into a subdirectory, or
    # load a direct .md child when the scan root permits it. Anything else is empty.
    def load_entry(full, name, include_root_files)
      return load_dir_internal(full, include_root_files: false) if File.directory?(full)
      return load_from(full) if include_root_files && name.end_with?(".md") && File.file?(full)

      [[], []]
    end
    private_class_method :load_entry

    # Load one skill file into the [skills, diagnostics] pair the walk accumulates,
    # dropping the skill (but keeping its diagnostics) when the file did not load.
    def load_from(file_path)
      skill, diagnostics = load_file(file_path)
      [skill ? [skill] : [], diagnostics]
    end
    private_class_method :load_from

    # Resolve one path from load_skills to its [skills, diagnostics]: a missing
    # path warns, a directory is walked, a markdown file is loaded, and anything
    # else warns. A read error along the way becomes a warning rather than raising.
    def resolve_path_skills(path)
      return [[], [warning("skill path does not exist", path)]] unless File.exist?(path)
      return load_dir_internal(path, include_root_files: true) if File.directory?(path)
      return load_from(path) if path.end_with?(".md")

      [[], [warning("skill path is not a markdown file", path)]]
    rescue StandardError => e
      [[], [warning(e.message, path)]]
    end
    private_class_method :resolve_path_skills

    # Fold one loaded skill into the running merge: skip it silently when its
    # underlying file was already loaded (realpath dedup), record a collision
    # diagnostic when its name is already taken (first-wins), or otherwise keep it
    # and remember its realpath. Mutates skill_map, real_paths, and collisions.
    def merge_skill(skill, skill_map, real_paths, collisions)
      real = real_path(skill.file_path)
      return if real_paths.key?(real)

      if skill_map.key?(skill.name)
        collisions << collision_for(skill, skill_map[skill.name])
      else
        skill_map[skill.name] = skill
        real_paths[real] = true
      end
    end
    private_class_method :merge_skill

    # Build the collision diagnostic for a losing skill against the winner that
    # already holds its name.
    def collision_for(loser, winner)
      Diagnostic.new(
        type: "collision",
        message: %(name "#{loser.name}" collision),
        path: loser.file_path,
        collision: Collision.new(resource_type: "skill", name: loser.name,
                                 winner_path: winner.file_path, loser_path: loser.file_path)
      )
    end
    private_class_method :collision_for

    # The canonical path of a file with symlinks resolved, used to detect the
    # same underlying file reached by two routes. Falls back to the given path if
    # it cannot be resolved.
    def real_path(path)
      File.realpath(path)
    rescue StandardError
      path
    end
    private_class_method :real_path

    # Wrap a single message as a warning diagnostic tied to a path.
    def warning(message, path)
      Diagnostic.new(type: "warning", message: message, path: path)
    end
    private_class_method :warning

    # The spec errors for a name: too long, characters outside lowercase a-z, 0-9
    # and hyphen, a leading or trailing hyphen, or consecutive hyphens. Ports pi's
    # validateName.
    def validate_name(name)
      errors = []
      if name.length > MAX_NAME_LENGTH
        errors << "name exceeds #{MAX_NAME_LENGTH} characters (#{name.length})"
      end
      unless /\A[a-z0-9-]+\z/.match?(name)
        errors << "name contains invalid characters (must be lowercase a-z, 0-9, hyphens only)"
      end
      if name.start_with?("-") || name.end_with?("-")
        errors << "name must not start or end with a hyphen"
      end
      errors << "name must not contain consecutive hyphens" if name.include?("--")
      errors
    end
    private_class_method :validate_name

    # The spec errors for a description: required, and at most 1024 characters.
    # Ports pi's validateDescription.
    def validate_description(description)
      return ["description is required"] if blank?(description)
      return [] unless description.length > MAX_DESCRIPTION_LENGTH

      ["description exceeds #{MAX_DESCRIPTION_LENGTH} characters (#{description.length})"]
    end
    private_class_method :validate_description

    # Wrap a list of validation messages as warning diagnostics tied to a path.
    def warnings(messages, path)
      messages.map { |message| Diagnostic.new(type: "warning", message: message, path: path) }
    end
    private_class_method :warnings

    def build_skill(name, description, file_path, frontmatter)
      Skill.new(
        name: name,
        description: description,
        file_path: file_path,
        base_dir: File.dirname(file_path),
        disable_model_invocation: frontmatter["disable-model-invocation"] == true
      )
    end
    private_class_method :build_skill

    def blank?(value)
      !value.is_a?(String) || value.strip.empty?
    end
    private_class_method :blank?

    def string_or_nil(value)
      value if value.is_a?(String) && !value.empty?
    end
    private_class_method :string_or_nil

    def escape_xml(str)
      str.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
         .gsub('"', "&quot;").gsub("'", "&apos;")
    end
    private_class_method :escape_xml
  end
end
