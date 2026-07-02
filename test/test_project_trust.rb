# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class TestProjectTrust < Minitest::Test
  PT = Truffle::ProjectTrust

  # --- parent_path -----------------------------------------------------------

  def test_parent_path_is_the_canonical_parent
    Dir.mktmpdir("truffle-trust") do |dir|
      assert_equal PT.normalize_cwd(File.dirname(dir)), PT.parent_path(dir)
    end
  end

  def test_parent_path_is_nil_at_the_filesystem_root
    assert_nil PT.parent_path("/")
  end

  # --- options ---------------------------------------------------------------

  def test_options_offers_trust_parent_and_do_not_trust
    Dir.mktmpdir("truffle-trust") do |dir|
      trust_path = PT.normalize_cwd(dir)
      parent = PT.parent_path(dir)
      options = PT.options(dir)

      assert_equal ["Trust", "Trust parent folder (#{parent})", "Do not trust"],
                   options.map(&:label)
      assert_equal [true, true, false], options.map(&:trusted)

      trust = options[0]

      assert_equal [PT::Update.new(trust_path, true)], trust.updates
      assert_equal trust_path, trust.saved_path

      trust_parent = options[1]

      assert_equal [PT::Update.new(parent, true), PT::Update.new(trust_path, nil)],
                   trust_parent.updates
      assert_equal parent, trust_parent.saved_path

      deny = options[2]

      assert_equal [PT::Update.new(trust_path, false)], deny.updates
      assert_equal trust_path, deny.saved_path
    end
  end

  def test_options_can_include_session_only_choices
    Dir.mktmpdir("truffle-trust") do |dir|
      options = PT.options(dir, include_session_only: true)

      assert_equal [
        "Trust",
        "Trust parent folder (#{PT.parent_path(dir)})",
        "Trust (this session only)",
        "Do not trust",
        "Do not trust (this session only)"
      ], options.map(&:label)

      session_trust = options[2]

      assert_empty session_trust.updates
      assert_nil session_trust.saved_path

      session_deny = options[4]

      assert_empty session_deny.updates
      assert_nil session_deny.saved_path
    end
  end

  def test_options_omits_parent_choice_at_the_root
    labels = PT.options("/").map(&:label)

    assert_equal ["Trust", "Do not trust"], labels
    refute(labels.any? { |label| label.start_with?("Trust parent") })
  end

  # --- trust_requiring_resources? --------------------------------------------

  def test_plain_directory_needs_no_trust
    Dir.mktmpdir("truffle-trust") do |dir|
      refute PT.trust_requiring_resources?(dir, home: dir)
    end
  end

  def test_config_dir_file_resource_requires_trust
    Dir.mktmpdir("truffle-trust") do |dir|
      config = File.join(dir, ".truffle")
      FileUtils.mkdir_p(config)
      File.write(File.join(config, "settings.json"), "{}")

      assert PT.trust_requiring_resources?(dir, home: Dir.home)
    end
  end

  def test_config_dir_subdirectory_resource_requires_trust
    Dir.mktmpdir("truffle-trust") do |dir|
      FileUtils.mkdir_p(File.join(dir, ".truffle", "extensions"))

      assert PT.trust_requiring_resources?(dir, home: Dir.home)
    end
  end

  def test_system_prompt_file_requires_trust
    Dir.mktmpdir("truffle-trust") do |dir|
      FileUtils.mkdir_p(File.join(dir, ".truffle"))
      File.write(File.join(dir, ".truffle", "SYSTEM.md"), "hi")

      assert PT.trust_requiring_resources?(dir, home: Dir.home)
    end
  end

  def test_agents_skills_in_cwd_requires_trust
    Dir.mktmpdir("truffle-trust") do |dir|
      FileUtils.mkdir_p(File.join(dir, ".agents", "skills"))

      assert PT.trust_requiring_resources?(dir, home: Dir.home)
    end
  end

  def test_agents_skills_in_ancestor_requires_trust
    Dir.mktmpdir("truffle-trust") do |dir|
      FileUtils.mkdir_p(File.join(dir, ".agents", "skills"))
      child = File.join(dir, "a", "b")
      FileUtils.mkdir_p(child)

      assert PT.trust_requiring_resources?(child, home: Dir.home)
    end
  end

  def test_user_home_agents_skills_is_not_project_trust
    Dir.mktmpdir("truffle-home") do |home|
      FileUtils.mkdir_p(File.join(home, ".agents", "skills"))

      refute PT.trust_requiring_resources?(home, home: home)
    end
  end

  def test_project_agents_skills_under_home_still_requires_trust
    Dir.mktmpdir("truffle-home") do |home|
      FileUtils.mkdir_p(File.join(home, ".agents", "skills"))
      project = File.join(home, "project")
      FileUtils.mkdir_p(File.join(project, ".agents", "skills"))

      assert PT.trust_requiring_resources?(project, home: home)
    end
  end

  # --- Store round-trips -----------------------------------------------------

  def test_unknown_directory_has_no_decision
    with_store do |store, _agent|
      Dir.mktmpdir("truffle-cwd") { |cwd| assert_nil store.get(cwd) }
    end
  end

  def test_set_and_get_a_decision
    with_store do |store, _agent|
      Dir.mktmpdir("truffle-cwd") do |cwd|
        store.set(cwd, true)

        assert store.get(cwd)

        store.set(cwd, false)

        refute store.get(cwd)
      end
    end
  end

  def test_decision_applies_to_descendant_directories
    with_store do |store, _agent|
      Dir.mktmpdir("truffle-cwd") do |parent|
        child = File.join(parent, "nested", "deep")
        FileUtils.mkdir_p(child)
        store.set(parent, true)

        entry = store.entry(child)

        assert entry.decision
        assert_equal PT.normalize_cwd(parent), entry.path
      end
    end
  end

  def test_nil_update_removes_a_decision
    with_store do |store, agent|
      Dir.mktmpdir("truffle-cwd") do |cwd|
        store.set(cwd, true)
        store.set(cwd, nil)

        assert_nil store.get(cwd)
        refute_includes JSON.parse(File.read(File.join(agent, "trust.json"))),
                        PT.normalize_cwd(cwd)
      end
    end
  end

  def test_trust_parent_option_moves_the_decision_up
    with_store do |store, _agent|
      Dir.mktmpdir("truffle-cwd") do |parent|
        child = File.join(parent, "sub")
        FileUtils.mkdir_p(child)

        trust_parent = PT.options(child).find { |o| o.label.start_with?("Trust parent") }
        store.set_many(trust_parent.updates)

        assert store.get(child)
        refute_includes store_data(store), PT.normalize_cwd(child)
        assert_includes store_data(store), PT.normalize_cwd(parent)
      end
    end
  end

  # --- Store persistence format ----------------------------------------------

  def test_trust_file_is_key_sorted_with_a_trailing_newline
    with_store do |store, agent|
      Dir.mktmpdir("truffle-cwd") do |base|
        b = File.join(base, "b")
        a = File.join(base, "a")
        FileUtils.mkdir_p(b)
        FileUtils.mkdir_p(a)
        store.set(b, true)
        store.set(a, false)

        raw = File.read(File.join(agent, "trust.json"))

        assert raw.end_with?("\n")
        assert_equal raw.chomp, JSON.pretty_generate(JSON.parse(raw))
        keys = JSON.parse(raw).keys

        assert_equal keys.sort, keys
      end
    end
  end

  # --- Store validation ------------------------------------------------------

  def test_non_object_trust_file_is_rejected
    with_store do |store, agent|
      File.write(File.join(agent, "trust.json"), "[]")

      error = assert_raises(Truffle::Error) { store.get("/anywhere") }
      assert_match(/expected an object/, error.message)
    end
  end

  def test_bad_value_in_trust_file_is_rejected
    with_store do |store, agent|
      File.write(File.join(agent, "trust.json"), '{"/x": "maybe"}')

      error = assert_raises(Truffle::Error) { store.get("/anywhere") }
      assert_match(/must be true, false, or null/, error.message)
    end
  end

  def test_malformed_json_trust_file_is_rejected
    with_store do |store, agent|
      File.write(File.join(agent, "trust.json"), "{not json")

      error = assert_raises(Truffle::Error) { store.get("/anywhere") }
      assert_match(/Failed to read trust store/, error.message)
    end
  end

  private

  def with_store
    Dir.mktmpdir("truffle-agent") do |agent|
      yield PT::Store.new(agent), agent
    end
  end

  def store_data(store)
    JSON.parse(File.read(store.instance_variable_get(:@trust_path)))
  end
end
