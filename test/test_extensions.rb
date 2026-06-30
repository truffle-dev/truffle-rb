# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

# Extension discovery, a port of the pure filesystem layer in pi's extension
# loader (core/extensions/loader.ts): isExtensionFile, readPiManifest,
# resolveExtensionEntries, discoverExtensionsInDir, and the Ruby registration
# loader foundation. Everything runs against a temp tree so the suite stays
# hermetic and offline.
class TestExtensions < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("truffle-extensions")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def write_file(rel, body = "")
    path = File.join(@dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
    path
  end

  # --- extension_file? --------------------------------------------------------

  def test_rb_files_are_extension_files
    assert Truffle::Extensions.extension_file?("plugin.rb")
  end

  def test_non_rb_files_are_not_extension_files
    refute Truffle::Extensions.extension_file?("README.md")
    refute Truffle::Extensions.extension_file?("plugin.ts")
    refute Truffle::Extensions.extension_file?("plugin")
  end

  # --- read_manifest ----------------------------------------------------------

  def test_read_manifest_returns_the_pi_object
    path = write_file("package.json", JSON.generate({ "pi" => { "extensions" => ["a.rb"] } }))

    assert_equal({ "extensions" => ["a.rb"] }, Truffle::Extensions.read_manifest(path))
  end

  def test_read_manifest_without_a_pi_field_is_nil
    path = write_file("package.json", JSON.generate({ "name" => "thing" }))

    assert_nil Truffle::Extensions.read_manifest(path)
  end

  def test_read_manifest_with_non_object_pi_field_is_nil
    path = write_file("package.json", JSON.generate({ "pi" => "nope" }))

    assert_nil Truffle::Extensions.read_manifest(path)
  end

  def test_read_manifest_with_malformed_json_is_nil
    path = write_file("package.json", "{ not json")

    assert_nil Truffle::Extensions.read_manifest(path)
  end

  def test_read_manifest_for_a_missing_file_is_nil
    assert_nil Truffle::Extensions.read_manifest(File.join(@dir, "absent.json"))
  end

  # --- resolve_entries --------------------------------------------------------

  def test_resolve_entries_prefers_manifest_extensions
    write_file("pkg/lib/a.rb")
    write_file("pkg/lib/b.rb")
    write_file("pkg/package.json",
               JSON.generate({ "pi" => { "extensions" => ["lib/a.rb", "lib/b.rb"] } }))

    entries = Truffle::Extensions.resolve_entries(File.join(@dir, "pkg"))

    assert_equal [File.join(@dir, "pkg/lib/a.rb"), File.join(@dir, "pkg/lib/b.rb")], entries
  end

  def test_resolve_entries_skips_declared_paths_that_do_not_exist
    write_file("pkg/lib/a.rb")
    write_file("pkg/package.json",
               JSON.generate({ "pi" => { "extensions" => ["lib/a.rb", "lib/missing.rb"] } }))

    entries = Truffle::Extensions.resolve_entries(File.join(@dir, "pkg"))

    assert_equal [File.join(@dir, "pkg/lib/a.rb")], entries
  end

  def test_resolve_entries_falls_back_to_index_when_manifest_declares_nothing_real
    write_file("pkg/index.rb")
    write_file("pkg/package.json",
               JSON.generate({ "pi" => { "extensions" => ["lib/missing.rb"] } }))

    entries = Truffle::Extensions.resolve_entries(File.join(@dir, "pkg"))

    assert_equal [File.join(@dir, "pkg/index.rb")], entries
  end

  def test_resolve_entries_uses_index_when_no_manifest
    write_file("pkg/index.rb")

    entries = Truffle::Extensions.resolve_entries(File.join(@dir, "pkg"))

    assert_equal [File.join(@dir, "pkg/index.rb")], entries
  end

  def test_resolve_entries_is_nil_when_nothing_qualifies
    write_file("pkg/notes.md")

    assert_nil Truffle::Extensions.resolve_entries(File.join(@dir, "pkg"))
  end

  def test_resolve_entries_empty_manifest_extensions_falls_through_to_nil
    write_file("pkg/package.json", JSON.generate({ "pi" => { "extensions" => [] } }))

    assert_nil Truffle::Extensions.resolve_entries(File.join(@dir, "pkg"))
  end

  # --- discover_in_dir --------------------------------------------------------

  def test_discover_returns_empty_for_a_missing_directory
    assert_empty Truffle::Extensions.discover_in_dir(File.join(@dir, "absent"))
  end

  def test_discover_finds_direct_rb_files
    write_file("ext/one.rb")
    write_file("ext/two.rb")
    write_file("ext/README.md")

    discovered = Truffle::Extensions.discover_in_dir(File.join(@dir, "ext"))

    assert_equal [File.join(@dir, "ext/one.rb"), File.join(@dir, "ext/two.rb")], discovered
  end

  def test_discover_descends_one_level_into_subdir_index
    write_file("ext/plugin/index.rb")

    discovered = Truffle::Extensions.discover_in_dir(File.join(@dir, "ext"))

    assert_equal [File.join(@dir, "ext/plugin/index.rb")], discovered
  end

  def test_discover_uses_subdir_manifest_over_index
    write_file("ext/plugin/index.rb")
    write_file("ext/plugin/real.rb")
    write_file("ext/plugin/package.json",
               JSON.generate({ "pi" => { "extensions" => ["real.rb"] } }))

    discovered = Truffle::Extensions.discover_in_dir(File.join(@dir, "ext"))

    assert_equal [File.join(@dir, "ext/plugin/real.rb")], discovered
  end

  def test_discover_does_not_recurse_beyond_one_level
    write_file("ext/plugin/nested/deep.rb")

    discovered = Truffle::Extensions.discover_in_dir(File.join(@dir, "ext"))

    assert_empty discovered
  end

  def test_discover_ignores_subdirs_with_no_entry_point
    write_file("ext/plugin/notes.md")
    write_file("ext/real.rb")

    discovered = Truffle::Extensions.discover_in_dir(File.join(@dir, "ext"))

    assert_equal [File.join(@dir, "ext/real.rb")], discovered
  end

  def test_discover_is_sorted_and_deterministic
    write_file("ext/b.rb")
    write_file("ext/a.rb")
    write_file("ext/c/index.rb")

    discovered = Truffle::Extensions.discover_in_dir(File.join(@dir, "ext"))

    assert_equal(
      [
        File.join(@dir, "ext/a.rb"),
        File.join(@dir, "ext/b.rb"),
        File.join(@dir, "ext/c/index.rb")
      ],
      discovered
    )
  end

  def test_discover_follows_a_symlinked_directory
    write_file("target/index.rb")
    FileUtils.mkdir_p(File.join(@dir, "ext"))
    File.symlink(File.join(@dir, "target"), File.join(@dir, "ext/linked"))

    discovered = Truffle::Extensions.discover_in_dir(File.join(@dir, "ext"))

    # pi joins the index onto the entry path without realpath-resolving the
    # symlink, so the entry comes back through the link, not via the target.
    assert_equal [File.join(@dir, "ext/linked/index.rb")], discovered
  end

  def test_discover_keeps_a_dangling_rb_symlink_as_a_direct_entry
    FileUtils.mkdir_p(File.join(@dir, "ext"))
    File.symlink(File.join(@dir, "gone.rb"), File.join(@dir, "ext/link.rb"))

    discovered = Truffle::Extensions.discover_in_dir(File.join(@dir, "ext"))

    assert_equal [File.join(@dir, "ext/link.rb")], discovered
  end

  # --- load_file / load_files -------------------------------------------------

  def test_load_file_exposes_registration_api
    path = write_file("hello.rb", <<~RUBY)
      tool = Truffle.tool("hello", "Say hello") do
        param :name, :string, required: true
        run { |name:| "Hello, \#{name}!" }
      end

      truffle.register_tool(tool)
      truffle.register_command("greet", description: "Greet someone") do |args|
        "Greetings, \#{args}"
      end
      truffle.register_command("noop") { "ok" }
      truffle.register_command("future_ctx") do |args, ctx|
        "\#{args} / \#{ctx.nil?}"
      end
      truffle.on("session_start") do |event, _ctx|
        event[:seen] = true
      end
      truffle.register_provider("demo", { models: ["demo-model"] })
    RUBY

    extension = Truffle::Extensions.load_file(path)

    assert_equal path, extension.path
    assert_equal File.expand_path(path), extension.resolved_path

    registered_tool = extension.tools.fetch("hello").definition

    assert_equal "Hello, Ada!", registered_tool.call("name" => "Ada")

    registry = Truffle::SlashCommands::Registry.new(commands: extension.commands.values)
    result = registry.resolve("/greet Ada")

    assert_equal :action, result.type
    assert_equal "Greetings, Ada", result.content
    assert_equal "ok", registry.resolve("/noop").content
    assert_equal "Ada / true", registry.resolve("/future_ctx Ada").content

    event = {}
    extension.handlers.fetch("session_start").first.call(event, nil)

    assert_equal({ seen: true }, event)

    registration = extension.provider_registrations.fetch(0)

    assert_equal "demo", registration.name
    assert_equal({ models: ["demo-model"] }, registration.config)
    assert_equal path, registration.source_path
  end

  def test_load_file_shares_event_bus_through_runtime
    event_file = File.join(@dir, "event.txt")
    path = write_file("events.rb", <<~RUBY)
      truffle.events.on("ping") do |data|
        File.write(#{event_file.inspect}, data)
      end
    RUBY

    runtime = Truffle::Extensions::Runtime.new
    Truffle::Extensions.load_file(path, runtime: runtime)
    runtime.events.emit("ping", "seen")

    assert_equal "seen", File.read(event_file)
  end

  def test_load_file_can_unregister_a_provider
    path = write_file("provider.rb", <<~RUBY)
      truffle.register_provider("demo", { models: ["demo-model"] })
      truffle.unregister_provider("demo")
    RUBY

    runtime = Truffle::Extensions::Runtime.new
    extension = Truffle::Extensions.load_file(path, runtime: runtime)

    assert_empty extension.provider_registrations
    assert_empty runtime.provider_registrations
  end

  def test_load_files_resolves_relative_paths_and_collects_errors
    write_file("good.rb", <<~RUBY)
      truffle.on("ready") { |_event| }
    RUBY
    write_file("bad.rb", "raise 'boom'")

    result = Truffle::Extensions.load_files(["good.rb", "bad.rb"], cwd: @dir)

    assert_equal ["good.rb"], result.extensions.map(&:path)
    assert_equal 1, result.errors.length
    assert_equal "bad.rb", result.errors.first.path
    assert_match(/Failed to load extension: boom/, result.errors.first.error)
  end

  def test_runtime_invalidation_marks_api_state_stale
    runtime = Truffle::Extensions::Runtime.new
    runtime.invalidate("stale runtime")

    error = assert_raises(Truffle::Error) { runtime.assert_active }
    assert_equal "stale runtime", error.message
  end
end
