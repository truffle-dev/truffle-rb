# frozen_string_literal: true

require_relative "skills"

module Truffle
  # System prompt construction, the Ruby port of pi's
  # packages/coding-agent/src/core/system-prompt.ts (buildSystemPrompt). It
  # assembles the string an agent runs under: either a caller's custom prompt or
  # the default coding-agent prompt, with a tools list, deduplicated guidelines,
  # an optional project-context block, the available-skills block, and a trailing
  # date and working directory.
  #
  # The assembly logic and ordering follow pi exactly. Two things are adapted for
  # Truffle rather than transliterated: the default prompt text names Truffle
  # instead of pi, and the documentation pointer references Truffle's own bundled
  # README and examples instead of pi's per-topic docs, which Truffle does not
  # ship. The current date is injectable so the offline tests stay deterministic;
  # pi reads `new Date()` directly.
  module SystemPrompt
    # The tools a default prompt assumes when the caller names none, matching pi's
    # `selectedTools || ["read", "bash", "edit", "write"]`.
    DEFAULT_TOOLS = %w[read bash edit write].freeze

    # The gem root, where the bundled README and examples live. Resolved from this
    # file so the documentation pointer names real paths at runtime.
    GEM_ROOT = File.expand_path("../..", __dir__)
    README_PATH = File.join(GEM_ROOT, "README.md")
    EXAMPLES_PATH = File.join(GEM_ROOT, "examples")

    module_function

    # Build the system prompt. `cwd` is required, the way pi requires it; every
    # other input is optional and defaults to pi's behavior. `now` is injected for
    # deterministic tests and defaults to the wall clock.
    def build(cwd:, custom_prompt: nil, selected_tools: nil, tool_snippets: nil,
              prompt_guidelines: nil, append_system_prompt: nil,
              context_files: nil, skills: nil, now: Time.now)
      prompt_cwd = cwd.tr("\\", "/")
      date = now.strftime("%Y-%m-%d")
      append_section = append_system_prompt ? "\n\n#{append_system_prompt}" : ""
      context_files ||= []
      skills ||= []

      if custom_prompt
        return build_custom(custom_prompt: custom_prompt, append_section: append_section,
                            context_files: context_files, skills: skills,
                            selected_tools: selected_tools, date: date, prompt_cwd: prompt_cwd)
      end

      build_default(selected_tools: selected_tools, tool_snippets: tool_snippets,
                    prompt_guidelines: prompt_guidelines, append_section: append_section,
                    context_files: context_files, skills: skills, date: date,
                    prompt_cwd: prompt_cwd)
    end

    # The custom-prompt branch: the caller's prompt, then the append section,
    # project context, skills (only when the read tool is available), and the
    # trailing date and cwd.
    def build_custom(custom_prompt:, append_section:, context_files:, skills:,
                     selected_tools:, date:, prompt_cwd:)
      prompt = custom_prompt.dup
      prompt += append_section
      prompt += project_context(context_files)

      has_read = selected_tools.nil? || selected_tools.include?("read")
      prompt += Skills.format_for_prompt(skills) if has_read && !skills.empty?

      prompt + trailer(date, prompt_cwd)
    end

    # The default-prompt branch: the Truffle coding-agent prompt with a tools
    # list and guidelines, then the same append/context/skills/trailer sequence.
    def build_default(selected_tools:, tool_snippets:, prompt_guidelines:, append_section:,
                      context_files:, skills:, date:, prompt_cwd:)
      tools = selected_tools || DEFAULT_TOOLS
      prompt = +<<~PROMPT.chomp
        You are an expert coding assistant operating inside Truffle, a Ruby agent harness. You help users by reading files, executing commands, editing code, and writing new files.

        Available tools:
        #{tools_list(tools, tool_snippets)}

        In addition to the tools above, you may have access to other custom tools depending on the project.

        Guidelines:
        #{guidelines(tools, prompt_guidelines)}

        Truffle documentation (read only when the user asks about Truffle itself, its API, tools, or examples):
        - README: #{README_PATH}
        - Examples: #{EXAMPLES_PATH} (custom tools, embedding)
        - When reading Truffle docs or examples, resolve those paths under the locations above, not the current working directory
      PROMPT

      prompt += append_section
      prompt += project_context(context_files)
      prompt += Skills.format_for_prompt(skills) if tools.include?("read") && !skills.empty?

      prompt + trailer(date, prompt_cwd)
    end

    # The "Available tools" body. A tool is listed only when the caller supplies a
    # non-empty one-line snippet for it, matching pi's `!!toolSnippets?.[name]`
    # truthiness where an empty string is falsy. "(none)" when nothing qualifies.
    def tools_list(tools, tool_snippets)
      visible = tools.select do |name|
        snippet = tool_snippets && tool_snippets[name]
        snippet && !snippet.empty?
      end
      return "(none)" if visible.empty?

      visible.map { |name| "- #{name}: #{tool_snippets[name]}" }.join("\n")
    end

    # The deduplicated, insertion-ordered guideline body. The bash-only file
    # exploration heuristic comes first, then the caller's guidelines (trimmed,
    # blanks dropped), then the two always-on lines. Duplicates are collapsed
    # globally, so a caller line equal to an always-on line is not repeated.
    def guidelines(tools, prompt_guidelines)
      list = []
      seen = {}
      add = lambda do |guideline|
        next if seen[guideline]

        seen[guideline] = true
        list << guideline
      end

      if tools.include?("bash") && !tools.include?("grep") &&
         !tools.include?("find") && !tools.include?("ls")
        add.call("Use bash for file operations like ls, rg, find")
      end

      (prompt_guidelines || []).each do |guideline|
        normalized = guideline.strip
        add.call(normalized) unless normalized.empty?
      end

      add.call("Be concise in your responses")
      add.call("Show file paths clearly when working with files")

      list.map { |g| "- #{g}" }.join("\n")
    end

    # The optional project-context block, empty when no files are supplied.
    def project_context(context_files)
      return "" if context_files.empty?

      out = +"\n\n<project_context>\n\n"
      out << "Project-specific instructions and guidelines:\n\n"
      context_files.each do |file|
        path = file[:path]
        content = file[:content]
        out << "<project_instructions path=\"#{path}\">\n#{content}\n</project_instructions>\n\n"
      end
      out << "</project_context>\n"
      out
    end

    # The trailing date and working directory, added last in both branches.
    def trailer(date, prompt_cwd)
      "\nCurrent date: #{date}\nCurrent working directory: #{prompt_cwd}"
    end
  end
end
