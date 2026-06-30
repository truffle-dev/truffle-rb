# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

# Skill loading, validation, and prompt formatting, a port of the single-file
# half of pi's skills.ts (loadSkillFromFile / validateName / validateDescription /
# formatSkillsForPrompt). Files live in a temp dir so the suite stays hermetic.
class TestSkills < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("truffle-skills")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def write_skill(rel, body)
    path = File.join(@dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
    path
  end

  def test_loads_a_well_formed_skill_with_no_diagnostics
    path = write_skill("deploy/SKILL.md",
                       "---\nname: deploy\ndescription: ship the app\n---\nsteps")

    skill, diagnostics = Truffle::Skills.load_file(path)

    assert_empty diagnostics
    assert_equal "deploy", skill.name
    assert_equal "ship the app", skill.description
    assert_equal path, skill.file_path
    assert_equal File.dirname(path), skill.base_dir
    refute skill.disable_model_invocation
  end

  def test_name_falls_back_to_the_parent_directory_when_frontmatter_omits_it
    path = write_skill("formatter/SKILL.md", "---\ndescription: formats code\n---\n")

    skill, = Truffle::Skills.load_file(path)

    assert_equal "formatter", skill.name
  end

  def test_a_missing_description_drops_the_skill_with_a_warning
    path = write_skill("broken/SKILL.md", "---\nname: broken\n---\nno description")

    skill, diagnostics = Truffle::Skills.load_file(path)

    assert_nil skill
    assert_includes diagnostics.map(&:message), "description is required"
  end

  def test_an_invalid_name_still_loads_but_warns
    path = write_skill("x/SKILL.md", "---\nname: BadName\ndescription: d\n---\n")

    skill, diagnostics = Truffle::Skills.load_file(path)

    refute_nil skill
    assert_equal "BadName", skill.name
    assert_includes diagnostics.map(&:message),
                    "name contains invalid characters (must be lowercase a-z, 0-9, hyphens only)"
  end

  def test_consecutive_and_edge_hyphens_in_a_name_warn
    path = write_skill("y/SKILL.md", "---\nname: -a--b-\ndescription: d\n---\n")

    _skill, diagnostics = Truffle::Skills.load_file(path)
    messages = diagnostics.map(&:message)

    assert_includes messages, "name must not start or end with a hyphen"
    assert_includes messages, "name must not contain consecutive hyphens"
  end

  def test_an_over_long_description_warns_but_loads
    long = "d" * (Truffle::Skills::MAX_DESCRIPTION_LENGTH + 1)
    path = write_skill("z/SKILL.md", "---\nname: z\ndescription: #{long}\n---\n")

    skill, diagnostics = Truffle::Skills.load_file(path)

    refute_nil skill
    max = Truffle::Skills::MAX_DESCRIPTION_LENGTH
    expected = "description exceeds #{max} characters (#{long.length})"

    assert_includes diagnostics.map(&:message), expected
  end

  def test_disable_model_invocation_is_read_from_frontmatter
    path = write_skill("hidden/SKILL.md",
                       "---\nname: hidden\ndescription: d\ndisable-model-invocation: true\n---\n")

    skill, = Truffle::Skills.load_file(path)

    assert skill.disable_model_invocation
  end

  def test_an_unreadable_path_yields_a_warning_and_no_skill
    skill, diagnostics = Truffle::Skills.load_file(File.join(@dir, "nope/SKILL.md"))

    assert_nil skill
    assert_equal 1, diagnostics.length
    assert_equal "warning", diagnostics.first.type
  end

  def test_format_for_prompt_emits_an_available_skills_block
    skill = Truffle::Skills::Skill.new(name: "deploy", description: "ship it",
                                       file_path: "/s/deploy/SKILL.md", base_dir: "/s/deploy",
                                       disable_model_invocation: false)

    prompt = Truffle::Skills.format_for_prompt([skill])

    assert_includes prompt, "<available_skills>"
    assert_includes prompt, "<name>deploy</name>"
    assert_includes prompt, "<description>ship it</description>"
    assert_includes prompt, "<location>/s/deploy/SKILL.md</location>"
    assert_includes prompt, "</available_skills>"
  end

  def test_format_for_prompt_hides_skills_with_model_invocation_disabled
    visible = Truffle::Skills::Skill.new(name: "a", description: "d", file_path: "/a",
                                         base_dir: "/", disable_model_invocation: false)
    hidden = Truffle::Skills::Skill.new(name: "b", description: "d", file_path: "/b", base_dir: "/",
                                        disable_model_invocation: true)

    prompt = Truffle::Skills.format_for_prompt([visible, hidden])

    assert_includes prompt, "<name>a</name>"
    refute_includes prompt, "<name>b</name>"
  end

  def test_format_for_prompt_is_empty_when_no_skill_is_visible
    hidden = Truffle::Skills::Skill.new(name: "b", description: "d", file_path: "/b", base_dir: "/",
                                        disable_model_invocation: true)

    assert_equal "", Truffle::Skills.format_for_prompt([hidden])
    assert_equal "", Truffle::Skills.format_for_prompt([])
  end

  def test_format_for_prompt_escapes_xml_metacharacters
    skill = Truffle::Skills::Skill.new(name: "a&b", description: "<d> \"q\" 'x'", file_path: "/p",
                                       base_dir: "/", disable_model_invocation: false)

    prompt = Truffle::Skills.format_for_prompt([skill])

    assert_includes prompt, "<name>a&amp;b</name>"
    assert_includes prompt, "<description>&lt;d&gt; &quot;q&quot; &apos;x&apos;</description>"
  end

  def names(skills)
    skills.map(&:name).sort
  end

  def test_load_dir_loads_a_skill_root_holding_a_skill_md
    write_skill("deploy/SKILL.md", "---\nname: deploy\ndescription: ship it\n---\n")

    skills, diagnostics = Truffle::Skills.load_dir(File.join(@dir, "deploy"))

    assert_empty diagnostics
    assert_equal ["deploy"], names(skills)
  end

  def test_load_dir_stops_recursing_once_a_skill_md_marks_a_root
    write_skill("kit/SKILL.md", "---\nname: kit\ndescription: the kit\n---\n")
    write_skill("kit/nested/SKILL.md", "---\nname: nested\ndescription: ignored\n---\n")

    skills, = Truffle::Skills.load_dir(File.join(@dir, "kit"))

    assert_equal ["kit"], names(skills)
  end

  def test_load_dir_finds_skill_md_roots_in_subdirectories
    write_skill("skills/deploy/SKILL.md", "---\nname: deploy\ndescription: ship it\n---\n")
    write_skill("skills/format/SKILL.md", "---\nname: format\ndescription: formats\n---\n")

    skills, = Truffle::Skills.load_dir(File.join(@dir, "skills"))

    assert_equal %w[deploy format], names(skills)
  end

  def test_load_dir_loads_direct_md_children_at_the_scan_root_only
    write_skill("skills/top.md", "---\nname: top\ndescription: a root skill\n---\n")
    write_skill("skills/sub/loose.md", "---\nname: loose\ndescription: not a skill root\n---\n")

    skills, = Truffle::Skills.load_dir(File.join(@dir, "skills"))

    assert_equal ["top"], names(skills)
  end

  def test_load_dir_skips_dotfiles_and_node_modules
    write_skill("skills/.hidden/SKILL.md", "---\nname: hidden\ndescription: dot\n---\n")
    write_skill("skills/node_modules/dep/SKILL.md", "---\nname: dep\ndescription: vendor\n---\n")
    write_skill("skills/real/SKILL.md", "---\nname: real\ndescription: kept\n---\n")

    skills, = Truffle::Skills.load_dir(File.join(@dir, "skills"))

    assert_equal ["real"], names(skills)
  end

  def test_load_dir_returns_nothing_for_a_missing_directory
    skills, diagnostics = Truffle::Skills.load_dir(File.join(@dir, "nope"))

    assert_empty skills
    assert_empty diagnostics
  end

  def test_load_dir_propagates_diagnostics_from_a_loaded_skill
    write_skill("skills/bad/SKILL.md", "---\nname: Bad_Name\ndescription: d\n---\n")

    skills, diagnostics = Truffle::Skills.load_dir(File.join(@dir, "skills"))

    assert_equal ["Bad_Name"], names(skills)
    assert_includes diagnostics.map(&:message),
                    "name contains invalid characters (must be lowercase a-z, 0-9, hyphens only)"
  end

  def test_load_dir_keeps_both_same_named_skills_for_later_collision_handling
    write_skill("skills/first/calendar/SKILL.md", "---\nname: calendar\ndescription: one\n---\n")
    write_skill("skills/second/calendar/SKILL.md", "---\nname: calendar\ndescription: two\n---\n")

    skills, = Truffle::Skills.load_dir(File.join(@dir, "skills"))

    assert_equal %w[calendar calendar], names(skills)
  end

  def test_load_skills_merges_skills_from_several_paths
    write_skill("a/deploy/SKILL.md", "---\nname: deploy\ndescription: ship\n---\n")
    write_skill("b/format/SKILL.md", "---\nname: format\ndescription: tidy\n---\n")

    skills, diagnostics = Truffle::Skills.load_skills(
      [File.join(@dir, "a"), File.join(@dir, "b")]
    )

    assert_empty diagnostics
    assert_equal %w[deploy format], names(skills)
  end

  def test_load_skills_loads_an_explicit_markdown_file
    path = write_skill("loose/top.md", "---\nname: top\ndescription: a root skill\n---\n")

    skills, diagnostics = Truffle::Skills.load_skills([path])

    assert_empty diagnostics
    assert_equal ["top"], names(skills)
  end

  def test_load_skills_warns_when_a_path_does_not_exist
    skills, diagnostics = Truffle::Skills.load_skills([File.join(@dir, "nope")])

    assert_empty skills
    assert_equal 1, diagnostics.length
    assert_equal "warning", diagnostics.first.type
    assert_includes diagnostics.first.message, "does not exist"
  end

  def test_load_skills_warns_when_a_path_is_not_a_markdown_file
    path = write_skill("notes/readme.txt", "not a skill")

    skills, diagnostics = Truffle::Skills.load_skills([path])

    assert_empty skills
    assert_includes diagnostics.map(&:message), "skill path is not a markdown file"
  end

  def test_load_skills_keeps_the_first_skill_of_a_colliding_name
    write_skill("first/calendar/SKILL.md", "---\nname: calendar\ndescription: the first\n---\n")
    write_skill("second/calendar/SKILL.md", "---\nname: calendar\ndescription: the second\n---\n")

    skills, = Truffle::Skills.load_skills(
      [File.join(@dir, "first"), File.join(@dir, "second")]
    )

    assert_equal ["calendar"], names(skills)
    assert_equal "the first", skills.first.description
  end

  def test_load_skills_records_a_collision_diagnostic_for_the_loser
    winner = write_skill("first/calendar/SKILL.md",
                         "---\nname: calendar\ndescription: the first\n---\n")
    loser = write_skill("second/calendar/SKILL.md",
                        "---\nname: calendar\ndescription: the second\n---\n")

    _skills, diagnostics = Truffle::Skills.load_skills(
      [File.join(@dir, "first"), File.join(@dir, "second")]
    )

    collisions = diagnostics.select { |d| d.type == "collision" }

    assert_equal 1, collisions.length
    detail = collisions.first.collision

    assert_equal "skill", detail.resource_type
    assert_equal "calendar", detail.name
    assert_equal winner, detail.winner_path
    assert_equal loser, detail.loser_path
  end

  def test_load_skills_collision_diagnostics_follow_the_load_warnings
    write_skill("first/calendar/SKILL.md", "---\nname: calendar\ndescription: the first\n---\n")
    write_skill("second/calendar/SKILL.md", "---\nname: calendar\ndescription: the second\n---\n")

    _skills, diagnostics = Truffle::Skills.load_skills(
      [File.join(@dir, "missing"),
       File.join(@dir, "first"),
       File.join(@dir, "second")]
    )

    assert_equal %w[warning collision], diagnostics.map(&:type)
  end

  def test_load_skills_deduplicates_the_same_file_reached_through_a_symlink
    target = write_skill("real/deploy/SKILL.md", "---\nname: deploy\ndescription: ship\n---\n")
    link = File.join(@dir, "link.md")
    File.symlink(target, link)

    skills, diagnostics = Truffle::Skills.load_skills([target, link])

    assert_equal ["deploy"], names(skills)
    refute(diagnostics.any? { |d| d.type == "collision" })
  end

  def skill(rel, name)
    write_skill(rel, "---\nname: #{name}\ndescription: d\n---\n")
  end

  def test_load_dir_prunes_a_subdirectory_named_in_a_gitignore
    write_skill("skills/.gitignore", "secret/\n")
    skill("skills/secret/SKILL.md", "secret")
    skill("skills/real/SKILL.md", "real")

    skills, diagnostics = Truffle::Skills.load_dir(File.join(@dir, "skills"))

    assert_empty diagnostics
    assert_equal ["real"], names(skills)
  end

  def test_load_dir_honors_a_dot_ignore_file
    write_skill("skills/.ignore", "vendor/\n")
    skill("skills/vendor/SKILL.md", "vendor")
    skill("skills/keep/SKILL.md", "keep")

    skills, = Truffle::Skills.load_dir(File.join(@dir, "skills"))

    assert_equal ["keep"], names(skills)
  end

  def test_load_dir_honors_a_dot_fdignore_file
    write_skill("skills/.fdignore", "build/\n")
    skill("skills/build/SKILL.md", "build")
    skill("skills/src/SKILL.md", "src")

    skills, = Truffle::Skills.load_dir(File.join(@dir, "skills"))

    assert_equal ["src"], names(skills)
  end

  def test_load_dir_prunes_a_direct_md_child_matched_by_a_pattern
    write_skill("skills/.gitignore", "draft.md\n")
    skill("skills/draft.md", "draft")
    skill("skills/top.md", "top")

    skills, = Truffle::Skills.load_dir(File.join(@dir, "skills"))

    assert_equal ["top"], names(skills)
  end

  def test_load_dir_re_includes_a_path_through_a_negation
    write_skill("skills/.gitignore", "*.md\n!keep.md\n")
    skill("skills/drop.md", "drop")
    skill("skills/keep.md", "keep")

    skills, = Truffle::Skills.load_dir(File.join(@dir, "skills"))

    assert_equal ["keep"], names(skills)
  end

  def test_load_dir_treats_a_comment_line_in_the_ignore_file_as_no_pattern
    write_skill("skills/.gitignore", "# a comment\nsecret/\n")
    skill("skills/secret/SKILL.md", "secret")
    skill("skills/real/SKILL.md", "real")

    skills, = Truffle::Skills.load_dir(File.join(@dir, "skills"))

    assert_equal ["real"], names(skills)
  end

  def test_load_dir_scopes_a_nested_ignore_file_to_its_own_subtree
    # The matcher accumulates across the whole walk, so the prefixing is what keeps
    # aaa's "target/" rule from leaking into the sibling zzz subtree (walked later).
    # Correctly anchored as "aaa/target/", it prunes aaa's target only; zzz/target
    # survives. Without the prefix the unanchored "target/" would prune both.
    write_skill("skills/aaa/.gitignore", "target/\n")
    skill("skills/aaa/target/SKILL.md", "aaatarget")
    skill("skills/aaa/keep/SKILL.md", "keep")
    skill("skills/zzz/target/SKILL.md", "zzztarget")

    skills, = Truffle::Skills.load_dir(File.join(@dir, "skills"))

    assert_equal %w[keep zzztarget], names(skills)
  end

  def test_load_dir_falls_through_an_ignored_skill_md_to_its_subdirectories
    write_skill("skills/.gitignore", "tool/SKILL.md\n")
    skill("skills/tool/SKILL.md", "tool")
    skill("skills/tool/inner/SKILL.md", "inner")

    skills, = Truffle::Skills.load_dir(File.join(@dir, "skills"))

    assert_equal ["inner"], names(skills)
  end
end
