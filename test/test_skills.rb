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
end
