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

    # A problem found while loading: a type ("warning"), a human message, and the
    # path it concerns. Ports the warning shape of pi's ResourceDiagnostic.
    Diagnostic = Struct.new(:type, :message, :path, keyword_init: true)

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
