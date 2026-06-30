# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"

# Prompt-template loading and expansion for slash-command style prompts, ported
# from pi's prompt-templates.ts. Command registry/actions are later slices.
class TestPromptTemplates < Minitest::Test
  PromptTemplates = Truffle::PromptTemplates

  def test_load_file_reads_frontmatter_metadata_and_body
    Dir.mktmpdir("truffle-prompts") do |dir|
      path = File.join(dir, "review.md")
      File.write(path, <<~MARKDOWN)
        ---
        description: Review a patch
        argument-hint: "<file>"
        ---
        Check $1 carefully.
      MARKDOWN

      template = PromptTemplates.load_file(path)

      assert_equal "review", template.name
      assert_equal "Review a patch", template.description
      assert_equal "<file>", template.argument_hint
      assert_equal "Check $1 carefully.", template.content
      assert_equal File.expand_path(path), template.file_path
    end
  end

  def test_load_file_falls_back_to_first_body_line_for_description
    Dir.mktmpdir("truffle-prompts") do |dir|
      path = File.join(dir, "summarize.md")
      File.write(path, "\n\nSummarize this text.\n\nDetails follow.")

      template = PromptTemplates.load_file(path)

      assert_equal "Summarize this text.", template.description
    end
  end

  def test_load_file_truncates_long_fallback_description
    Dir.mktmpdir("truffle-prompts") do |dir|
      path = File.join(dir, "long.md")
      first_line = "a" * 61
      File.write(path, "#{first_line}\nbody")

      template = PromptTemplates.load_file(path)

      expected = "#{"a" * 60}..."

      assert_equal expected, template.description
    end
  end

  def test_load_file_returns_nil_for_missing_or_invalid_files
    Dir.mktmpdir("truffle-prompts") do |dir|
      invalid = File.join(dir, "bad.md")
      File.write(invalid, "---\n[\n---\nbody")

      assert_nil PromptTemplates.load_file(File.join(dir, "missing.md"))
      assert_nil PromptTemplates.load_file(invalid)
    end
  end

  def test_load_dir_scans_direct_markdown_files_in_sorted_order
    Dir.mktmpdir("truffle-prompts") do |dir|
      File.write(File.join(dir, "b.md"), "B")
      File.write(File.join(dir, "a.md"), "A")
      File.write(File.join(dir, "notes.txt"), "skip")
      subdir = File.join(dir, "nested")
      Dir.mkdir(subdir)
      File.write(File.join(subdir, "c.md"), "skip")

      templates = PromptTemplates.load_dir(dir)

      assert_equal %w[a b], templates.map(&:name)
      assert_equal %w[A B], templates.map(&:content)
    end
  end

  def test_load_paths_resolves_relative_files_and_directories
    Dir.mktmpdir("truffle-prompts") do |dir|
      prompts = File.join(dir, "prompts")
      Dir.mkdir(prompts)
      File.write(File.join(prompts, "dir-template.md"), "From dir")
      File.write(File.join(dir, "file-template.md"), "From file")
      File.write(File.join(dir, "ignore.txt"), "skip")

      templates = PromptTemplates.load_paths(
        ["prompts", "file-template.md", "ignore.txt", "missing.md"],
        cwd: dir
      )

      assert_equal %w[dir-template file-template], templates.map(&:name)
    end
  end

  def test_load_all_reads_default_dirs_then_explicit_paths
    Dir.mktmpdir("truffle-prompts") do |dir|
      agent_dir = File.join(dir, "agent")
      user_prompts = File.join(agent_dir, "prompts")
      project_prompts = File.join(dir, ".truffle", "prompts")
      explicit_prompts = File.join(dir, "extra")
      [user_prompts, project_prompts, explicit_prompts].each { |path| FileUtils.mkdir_p(path) }
      File.write(File.join(user_prompts, "user.md"), "User")
      File.write(File.join(project_prompts, "project.md"), "Project")
      File.write(File.join(explicit_prompts, "explicit.md"), "Explicit")

      templates = PromptTemplates.load_all(
        cwd: dir,
        agent_dir: agent_dir,
        prompt_paths: ["extra"]
      )

      assert_equal %w[user project explicit], templates.map(&:name)
    end
  end

  def test_load_all_can_skip_project_prompt_dir
    Dir.mktmpdir("truffle-prompts") do |dir|
      agent_dir = File.join(dir, "agent")
      user_prompts = File.join(agent_dir, "prompts")
      project_prompts = File.join(dir, ".truffle", "prompts")
      [user_prompts, project_prompts].each { |path| FileUtils.mkdir_p(path) }
      File.write(File.join(user_prompts, "user.md"), "User")
      File.write(File.join(project_prompts, "project.md"), "Project")

      templates = PromptTemplates.load_all(cwd: dir, agent_dir: agent_dir, include_project: false)

      assert_equal %w[user], templates.map(&:name)
    end
  end

  def test_load_all_can_skip_default_prompt_dirs
    Dir.mktmpdir("truffle-prompts") do |dir|
      agent_dir = File.join(dir, "agent")
      user_prompts = File.join(agent_dir, "prompts")
      explicit_prompts = File.join(dir, "extra")
      [user_prompts, explicit_prompts].each { |path| FileUtils.mkdir_p(path) }
      File.write(File.join(user_prompts, "user.md"), "User")
      File.write(File.join(explicit_prompts, "explicit.md"), "Explicit")

      templates = PromptTemplates.load_all(
        cwd: dir,
        agent_dir: agent_dir,
        prompt_paths: "extra",
        include_defaults: false
      )

      assert_equal %w[explicit], templates.map(&:name)
    end
  end

  def test_load_all_ignores_missing_default_prompt_dirs
    Dir.mktmpdir("truffle-prompts") do |dir|
      templates = PromptTemplates.load_all(cwd: dir, agent_dir: File.join(dir, "missing-agent"))

      assert_empty templates
    end
  end

  def test_parse_command_args_splits_on_whitespace
    args = PromptTemplates.parse_command_args("one two\tthree\nfour")

    assert_equal %w[one two three four], args
  end

  def test_parse_command_args_groups_single_and_double_quotes
    args = PromptTemplates.parse_command_args(%(one "two words" 'three more'))

    assert_equal ["one", "two words", "three more"], args
  end

  def test_parse_command_args_keeps_unclosed_quote_content
    args = PromptTemplates.parse_command_args(%(one "two words))

    assert_equal ["one", "two words"], args
  end

  def test_substitute_args_replaces_positionals_and_all_arguments
    out = PromptTemplates.substitute_args(
      "first=$1 second=$2 third=$3 all=$@ args=$ARGUMENTS",
      %w[alpha beta]
    )

    assert_equal "first=alpha second=beta third= all=alpha beta args=alpha beta", out
  end

  def test_substitute_args_uses_defaults_for_missing_or_empty_values
    out = PromptTemplates.substitute_args(
      "one=${1:-fallback} two=${2:-fallback} three=${3:-fallback}",
      ["present", ""]
    )

    assert_equal "one=present two=fallback three=fallback", out
  end

  def test_substitute_args_expands_argument_slices
    out = PromptTemplates.substitute_args(
      "tail=${@:2} pair=${@:2:2} zero=${@:0}",
      %w[one two three four]
    )

    assert_equal "tail=two three four pair=two three zero=one two three four", out
  end

  def test_substitute_args_out_of_range_slice_is_empty
    out = PromptTemplates.substitute_args("later=${@:9}", %w[one two])

    assert_equal "later=", out
  end

  def test_substitute_args_is_single_pass
    out = PromptTemplates.substitute_args("$1 ${2:-$1}", ["$2"])

    assert_equal "$2 $1", out
  end

  def test_expand_replaces_known_slash_command
    template = PromptTemplates::Template.new(
      name: "review",
      description: "Review",
      content: "Review $1 with $@"
    )

    out = PromptTemplates.expand(%(/review "lib/truffle.rb" carefully), [template])

    assert_equal "Review lib/truffle.rb with lib/truffle.rb carefully", out
  end

  def test_expand_leaves_plain_text_and_unknown_commands_unchanged
    template = PromptTemplates::Template.new(
      name: "known",
      description: "Known",
      content: "Known"
    )

    assert_equal "plain text", PromptTemplates.expand("plain text", [template])
    assert_equal "/missing arg", PromptTemplates.expand("/missing arg", [template])
  end
end
