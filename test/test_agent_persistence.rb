# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# Agent#dump / Agent.load round-trip an agent through a session file so a
# conversation can be paused and resumed. The session stores the history, the
# model, and the tool names; the provider, the tool implementations, and the
# system prompt are re-supplied on load.
class TestAgentPersistence < Minitest::Test
  def setup
    @add = Truffle::Tool.define("add", "Add two integers") do
      param :a, :integer, required: true
      param :b, :integer, required: true
      run { |a:, b:| a + b }
    end
  end

  def dumped_agent(dir, provider:, **opts)
    agent = Truffle::Agent.new(provider: provider, **opts)
    yield agent if block_given?
    agent.dump(dir: dir)
  end

  def usage_for(input:, output:)
    Truffle::Usage.parse(
      { "prompt_tokens" => input, "completion_tokens" => output },
      pricing: Truffle::Pricing.cost_for("gpt-5.4-mini")
    )
  end

  def test_dump_then_load_continues_the_conversation
    Dir.mktmpdir("truffle-agent") do |dir|
      session = dumped_agent(dir, provider: StubProvider.new([StubProvider.text("Hi there.")]),
                                  system_prompt: "be brief") do |agent|
        agent.run("hello")
      end

      resumed = StubProvider.new([StubProvider.text("Still here.")])
      agent = Truffle::Agent.load(session.file, provider: resumed, system_prompt: "be brief")
      agent.run("are you there?")

      # The first chat call on the resumed agent must see the whole prior
      # conversation, system prompt first, then the new user turn.
      seen = resumed.calls.first[:messages]
      roles = seen.map { |message| message[:role] }

      assert_equal %i[system user assistant user], roles
      assert_equal "hello", Truffle::Message.from_h(seen[1]).text
    end
  end

  def test_dump_without_a_dir_writes_to_the_default_per_project_directory
    Dir.mktmpdir("truffle-agent") do |home|
      agent_dir = File.join(home, "agent")
      with_env("TRUFFLE_AGENT_DIR" => agent_dir) do
        agent = Truffle::Agent.new(provider: StubProvider.new([StubProvider.text("ok")]))
        agent.run("hello")

        session = agent.dump(cwd: "/home/ada/proj")

        expected = Truffle::Config.default_session_dir(cwd: "/home/ada/proj", agent_dir: agent_dir)

        assert_equal expected, File.dirname(session.file)
        assert_path_exists session.file
      end
    end
  end

  def with_env(overrides)
    previous = {}
    overrides.each_key { |key| previous[key] = ENV.fetch(key, :__absent__) }
    overrides.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each do |key, value|
      value == :__absent__ ? ENV.delete(key) : ENV[key] = value
    end
  end

  def test_dump_then_load_preserves_accumulated_usage
    Dir.mktmpdir("truffle-agent") do |dir|
      first_usage = usage_for(input: 100, output: 10)
      second_usage = usage_for(input: 200, output: 20)
      agent = Truffle::Agent.new(
        provider: StubProvider.new([StubProvider.text("first", usage: first_usage)])
      )
      agent.run("hello")

      session = agent.dump(dir: dir)
      loaded = Truffle::Agent.load(
        session.file,
        provider: StubProvider.new([StubProvider.text("second", usage: second_usage)])
      )

      assert_equal first_usage, loaded.usage

      loaded.run("again")

      assert_equal first_usage + second_usage, loaded.usage
      assert_equal "usage", Truffle::Session.load(session.file).entries.last[:type]
    end
  end

  def test_dump_persists_the_tool_names_in_the_header
    Dir.mktmpdir("truffle-agent") do |dir|
      session = dumped_agent(dir, provider: StubProvider.new([StubProvider.text("ok")]),
                                  tools: [@add])

      assert_equal ["add"], Truffle::Session.load(session.file).tools
    end
  end

  def test_load_rebinds_the_toolbox_by_name
    Dir.mktmpdir("truffle-agent") do |dir|
      session = dumped_agent(dir, provider: StubProvider.new([StubProvider.text("ok")]),
                                  tools: [@add])

      provider = StubProvider.new([
                                    StubProvider.tool_call(id: "c1", name: "add",
                                                           arguments: { "a" => 2, "b" => 3 }),
                                    StubProvider.text("5")
                                  ])
      agent = Truffle::Agent.load(session.file, provider: provider, tools: [@add])

      assert_equal "5", agent.run("add 2 and 3")
      assert_equal %w[add], agent.toolbox.names
    end
  end

  def test_load_can_rebind_required_tools_from_extensions
    Dir.mktmpdir("truffle-agent") do |dir|
      extension_path = File.join(dir, "math_ext.rb")
      File.write(extension_path, <<~RUBY)
        truffle.register_tool(
          Truffle.tool("multiply", "Multiply two integers") do
            param :a, :integer, required: true
            param :b, :integer, required: true
            run { |a:, b:| a * b }
          end
        )
      RUBY
      extensions = Truffle::Extensions.load_files([extension_path])
      session = dumped_agent(dir, provider: StubProvider.new([StubProvider.text("ok")]),
                                  extensions: extensions)

      provider = StubProvider.new([
                                    StubProvider.tool_call(id: "c1", name: "multiply",
                                                           arguments: { "a" => 3, "b" => 4 }),
                                    StubProvider.text("12")
                                  ])
      agent = Truffle::Agent.load(session.file, provider: provider, extensions: extensions)

      assert_equal "12", agent.run("multiply 3 and 4")
      assert_equal %w[multiply], agent.toolbox.names
    end
  end

  def test_load_raises_when_a_required_tool_is_not_supplied
    Dir.mktmpdir("truffle-agent") do |dir|
      session = dumped_agent(dir, provider: StubProvider.new([StubProvider.text("ok")]),
                                  tools: [@add])

      error = assert_raises(Truffle::Error) do
        Truffle::Agent.load(session.file, provider: StubProvider.new([]), tools: [])
      end
      assert_includes error.message, "add"
    end
  end

  def test_load_can_rebuild_a_recorded_extension_provider
    Dir.mktmpdir("truffle-agent") do |dir|
      extension_path = File.join(dir, "provider_ext.rb")
      File.write(extension_path, <<~RUBY)
        truffle.register_provider("local", {
          api: :openai_completions,
          base_url: "http://localhost:11434/v1",
          api_key: "test-key",
          model: "llama3"
        })
      RUBY
      extensions = Truffle::Extensions.load_files([extension_path])
      session = dumped_agent(dir, provider: StubProvider.new([StubProvider.text("ok")]),
                                  model: "llama3")
      session.append_model_change(provider: "local", model_id: "llama3")

      agent = Truffle::Agent.load(session.file, extensions: extensions)

      assert_instance_of Truffle::Providers::OpenAI, agent.provider
      assert_equal "local", agent.provider.name
      assert_equal "http://localhost:11434/v1", agent.provider.base_url
      assert_equal "llama3", agent.instance_variable_get(:@model)
    end
  end

  def test_load_without_provider_requires_a_recorded_provider
    Dir.mktmpdir("truffle-agent") do |dir|
      session = dumped_agent(dir, provider: StubProvider.new([StubProvider.text("ok")]))

      error = assert_raises(Truffle::Error) { Truffle::Agent.load(session.file) }

      assert_match(/session has no recorded provider/, error.message)
      assert_match(/pass provider:/, error.message)
    end
  end

  def test_dump_records_the_model_and_load_restores_it
    Dir.mktmpdir("truffle-agent") do |dir|
      session = dumped_agent(dir, provider: StubProvider.new([StubProvider.text("ok")]),
                                  model: "gpt-4o-mini")

      assert_equal "gpt-4o-mini", Truffle::Session.load(session.file).context.model.model_id

      resumed = StubProvider.new([StubProvider.text("hi")])
      agent = Truffle::Agent.load(session.file, provider: resumed)
      agent.run("ping")

      # The restored model threads through to the provider on the next turn.
      assert_equal "gpt-4o-mini", resumed.calls.first[:model]
    end
  end

  def test_explicit_model_overrides_the_recorded_one
    Dir.mktmpdir("truffle-agent") do |dir|
      session = dumped_agent(dir, provider: StubProvider.new([StubProvider.text("ok")]),
                                  model: "gpt-4o-mini")

      resumed = StubProvider.new([StubProvider.text("hi")])
      agent = Truffle::Agent.load(session.file, provider: resumed, model: "gpt-4o")
      agent.run("ping")

      assert_equal "gpt-4o", resumed.calls.first[:model]
    end
  end

  def test_dump_leaves_the_system_prompt_out_of_the_session
    Dir.mktmpdir("truffle-agent") do |dir|
      session = dumped_agent(dir, provider: StubProvider.new([StubProvider.text("hi")]),
                                  system_prompt: "secret system prompt") do |agent|
        agent.run("hello")
      end

      roles = Truffle::Session.load(session.file).messages.map(&:role)

      refute_includes roles, :system
      assert_equal %i[user assistant], roles
    end
  end

  def test_dump_of_a_modelless_agent_writes_no_model_change
    Dir.mktmpdir("truffle-agent") do |dir|
      session = dumped_agent(dir, provider: StubProvider.new([StubProvider.text("ok")]))

      assert_nil Truffle::Session.load(session.file).context.model
    end
  end

  def test_restore_keeps_the_system_prompt_at_the_front
    agent = Truffle::Agent.new(provider: StubProvider.new([]), system_prompt: "sys")
    agent.restore([Truffle::Message.user("resumed turn")])

    assert_equal %i[system user], agent.messages.map(&:role)
    assert_equal "resumed turn", agent.messages.last.text
  end
end
