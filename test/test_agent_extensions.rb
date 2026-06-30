# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

# Loaded extensions are plain registration data until an agent binds them. These
# tests cover the first runtime binding slice: tools join the toolbox and slash
# commands join the command registry.
class TestAgentExtensions < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("truffle-agent-extensions")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def write_extension(rel, body)
    path = File.join(@dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
    path
  end

  def load_extension(body)
    path = write_extension("ext.rb", body)
    Truffle::Extensions.load_files([path])
  end

  def test_extension_tool_is_available_to_agent
    extensions = load_extension(<<~'RUBY')
      tool = Truffle.tool("lookup", "Lookup a value") do
        param :key, :string, required: true
        run { |key:| "value:#{key}" }
      end
      truffle.register_tool(tool)
    RUBY
    provider = StubProvider.new([
                                  StubProvider.tool_call(id: "c1", name: "lookup",
                                                         arguments: { "key" => "alpha" }),
                                  StubProvider.text("done")
                                ])

    agent = Truffle::Agent.new(provider: provider, extensions: extensions)
    result = agent.run("lookup alpha")

    assert_equal "done", result
    assert_includes provider.calls.first[:tools].map { |tool| tool[:name] }, "lookup"
    assert_equal "value:alpha", agent.messages.find { |message| message.role == :tool }.text
  end

  def test_application_tool_overrides_extension_tool_with_same_name
    extensions = load_extension(<<~RUBY)
      tool = Truffle.tool("echo", "Extension echo") do
        run { "extension" }
      end
      truffle.register_tool(tool)
    RUBY
    app_tool = Truffle.tool("echo", "App echo") { run { "app" } }
    provider = StubProvider.new([
                                  StubProvider.tool_call(id: "c1", name: "echo", arguments: {}),
                                  StubProvider.text("done")
                                ])

    agent = Truffle::Agent.new(provider: provider, tools: [app_tool], extensions: extensions)
    agent.run("echo")

    assert_equal "app", agent.messages.find { |message| message.role == :tool }.text
    assert_equal ["echo"], agent.toolbox.names
  end

  def test_extension_command_runs_without_provider_turn
    extensions = load_extension(<<~'RUBY')
      truffle.register_command("hello", description: "Say hello") do |args|
        "hello #{args}"
      end
    RUBY
    provider = StubProvider.new([StubProvider.text("should not be used")])
    agent = Truffle::Agent.new(provider: provider, extensions: extensions)

    result = agent.run("/hello Ada")

    assert_equal "hello Ada", result
    assert_empty provider.calls
  end

  def test_extension_commands_share_duplicate_suffixing
    first = load_extension("truffle.register_command('dupe') { 'one' }")
    second = load_extension("truffle.register_command('dupe') { 'two' }")
    provider = StubProvider.new([StubProvider.text("should not be used")])
    agent = Truffle::Agent.new(provider: provider, extensions: [first, second])

    assert_equal "one", agent.run("/dupe:1")
    assert_equal "two", agent.run("/dupe:2")
    assert_empty provider.calls
  end

  def test_agent_registry_does_not_mutate_loaded_extension_commands
    extensions = load_extension("truffle.register_command('ping') { 'pong' }")
    command = extensions.extensions.first.commands.fetch("ping")
    provider = StubProvider.new([StubProvider.text("should not be used")])

    assert_nil command.invocation_name

    Truffle::Agent.new(provider: provider, extensions: extensions).run("/ping")

    assert_nil command.invocation_name
  end

  def test_truffle_agent_factory_passes_extensions_through
    extensions = load_extension("truffle.register_command('ping') { 'pong' }")
    provider = StubProvider.new([StubProvider.text("should not be used")])
    agent = Truffle.agent(provider: provider, extensions: extensions)

    assert_equal "pong", agent.run("/ping")
  end
end
