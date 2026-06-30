# frozen_string_literal: true

require "test_helper"

# System prompt assembly, a port of pi's buildSystemPrompt
# (core/system-prompt.ts). Every test pins one branch of the assembly: the
# custom-prompt path, the default coding-agent path, tools-list visibility,
# guideline dedup and ordering, the project-context block, the read-gated
# skills block, and the trailing date and cwd. `now:` is injected so the date
# line is deterministic offline.
class TestSystemPrompt < Minitest::Test
  FIXED_NOW = Time.new(2026, 6, 30, 12, 0, 0)

  def build(**kwargs)
    Truffle::SystemPrompt.build(cwd: "/work", now: FIXED_NOW, **kwargs)
  end

  def skill(name:, description:, file_path:, disable_model_invocation: false)
    Truffle::Skills::Skill.new(
      name: name,
      description: description,
      file_path: file_path,
      base_dir: File.dirname(file_path),
      disable_model_invocation: disable_model_invocation
    )
  end

  # --- custom-prompt branch ---------------------------------------------------

  def test_custom_prompt_is_returned_verbatim_with_trailer
    result = build(custom_prompt: "Do the thing.")

    assert_equal "Do the thing.\nCurrent date: 2026-06-30\nCurrent working directory: /work", result
  end

  def test_custom_prompt_does_not_carry_the_default_body
    result = build(custom_prompt: "Just this.")

    refute_includes result, "expert coding assistant"
    refute_includes result, "Available tools:"
  end

  def test_append_section_follows_the_custom_prompt
    result = build(custom_prompt: "Base.", append_system_prompt: "Extra rule.")

    assert_includes result, "Base.\n\nExtra rule."
  end

  # --- default branch ---------------------------------------------------------

  def test_default_prompt_names_truffle_and_lists_the_trailer
    result = build

    assert_includes result, "operating inside Truffle, a Ruby agent harness"
    assert_includes result, "Current date: 2026-06-30"
    assert_includes result, "Current working directory: /work"
  end

  def test_default_documentation_pointer_resolves_gem_paths
    result = build

    assert_includes result, "- README: #{Truffle::SystemPrompt::README_PATH}"
    assert_includes result, "- Examples: #{Truffle::SystemPrompt::EXAMPLES_PATH}"
  end

  # --- tools list -------------------------------------------------------------

  def test_tools_list_is_none_without_snippets
    result = build

    assert_includes result, "Available tools:\n(none)"
  end

  def test_tools_list_shows_only_tools_with_a_nonempty_snippet
    result = build(
      selected_tools: %w[read bash edit],
      tool_snippets: { "read" => "read a file", "bash" => "", "edit" => "edit a file" }
    )

    assert_includes result, "- read: read a file"
    assert_includes result, "- edit: edit a file"
    refute_includes result, "- bash:"
  end

  # --- guidelines -------------------------------------------------------------

  def test_bash_only_exploration_guideline_is_added
    result = build(selected_tools: %w[bash])

    assert_includes result, "- Use bash for file operations like ls, rg, find"
  end

  def test_bash_exploration_guideline_suppressed_when_grep_present
    result = build(selected_tools: %w[bash grep])

    refute_includes result, "Use bash for file operations"
  end

  def test_caller_guidelines_are_trimmed_and_blanks_dropped
    result = build(prompt_guidelines: ["  Prefer small diffs  ", "   ", ""])

    assert_includes result, "- Prefer small diffs"
    refute_includes result, "-  Prefer"
  end

  def test_guidelines_are_deduplicated_in_insertion_order
    result = build(
      selected_tools: %w[bash],
      prompt_guidelines: [
        "Be concise in your responses",
        "Use bash for file operations like ls, rg, find"
      ]
    )
    section = result[/Guidelines:\n(.*?)\n\nTruffle documentation/m, 1]

    assert_equal(
      [
        "- Use bash for file operations like ls, rg, find",
        "- Be concise in your responses",
        "- Show file paths clearly when working with files"
      ],
      section.lines.map(&:chomp)
    )
  end

  # --- project context --------------------------------------------------------

  def test_project_context_block_is_absent_without_files
    result = build

    refute_includes result, "<project_context>"
  end

  def test_project_context_block_wraps_each_file
    result = build(context_files: [{ path: "AGENTS.md", content: "house rules" }])
    expected = "<project_instructions path=\"AGENTS.md\">\nhouse rules\n</project_instructions>"

    assert_includes result, "<project_context>"
    assert_includes result, expected
  end

  # --- skills block -----------------------------------------------------------

  def test_skills_block_appears_when_read_tool_is_available
    s = skill(name: "deploy", description: "ship it", file_path: "/skills/deploy/SKILL.md")
    result = build(skills: [s])

    assert_includes result, "<available_skills>"
    assert_includes result, "<name>deploy</name>"
  end

  def test_skills_block_is_gated_off_when_read_tool_is_absent
    s = skill(name: "deploy", description: "ship it", file_path: "/skills/deploy/SKILL.md")
    result = build(selected_tools: %w[bash edit write], skills: [s])

    refute_includes result, "<available_skills>"
  end

  def test_custom_prompt_skills_block_respects_explicit_tool_selection
    s = skill(name: "deploy", description: "ship it", file_path: "/skills/deploy/SKILL.md")
    with_read = build(custom_prompt: "Base.", selected_tools: %w[read], skills: [s])
    without_read = build(custom_prompt: "Base.", selected_tools: %w[bash], skills: [s])

    assert_includes with_read, "<available_skills>"
    refute_includes without_read, "<available_skills>"
  end

  # --- trailer ----------------------------------------------------------------

  def test_backslash_cwd_is_normalized_to_forward_slashes
    result = Truffle::SystemPrompt.build(cwd: "C:\\Users\\me", now: FIXED_NOW)

    assert_includes result, "Current working directory: C:/Users/me"
  end
end
