# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

# Loaded extensions are plain registration data until an agent binds them. These
# tests cover the first runtime binding slice: tools join the toolbox and slash
# commands join the command registry.
class TestAgentExtensions < Minitest::Test
  def setup
    Truffle::ProviderRegistry.clear
    @dir = Dir.mktmpdir("truffle-agent-extensions")
  end

  def teardown
    FileUtils.remove_entry(@dir)
    Truffle::ProviderRegistry.clear
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

  def capture_openai_chat
    original = Truffle::Providers::OpenAI.instance_method(:chat)
    calls = []
    Truffle::Providers::OpenAI.define_method(:chat) do |messages:, tools: [], model: nil, **options|
      calls << {
        base_url: base_url,
        headers: send(:request_headers),
        messages: messages,
        model: model,
        options: options,
        tools: tools
      }
      StubProvider.text("done")
    end
    yield calls
  ensure
    Truffle::Providers::OpenAI.define_method(:chat, original)
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

  def test_extension_command_receives_runtime_command_context
    log_path = File.join(@dir, "command_context.log")
    session = Truffle::Session.create(dir: File.join(@dir, "sessions"), cwd: @dir)
    model = Truffle::Models.find("gpt-4o-mini")
    signal = Truffle::AbortSignal.new
    extensions = load_extension(<<~RUBY)
      log_path = #{log_path.inspect}

      truffle.register_command("inspect", description: "Inspect context") do |args, ctx|
        File.open(log_path, "w") do |file|
          file.puts "args=\#{args}"
          file.puts "context=\#{ctx.class.name}"
          file.puts "command=\#{ctx.command.name}:\#{ctx.command.invocation_name}"
          file.puts "parsed=\#{ctx.args.join("|")}"
          file.puts "agent=\#{ctx.agent.class.name}"
          file.puts "provider=\#{ctx.provider.name}"
          file.puts "model=\#{ctx.model}"
          file.puts "model_spec=\#{ctx.model_spec.name}"
          file.puts "session_cwd=\#{ctx.session.cwd}"
          file.puts "cwd=\#{ctx.cwd}"
          file.puts "system=\#{ctx.system_prompt}"
          file.puts "usage=\#{ctx.context_usage.input}"
          file.puts "signal=\#{ctx.signal.class.name}"
          file.puts "session_name=\#{ctx.session_name}"
          file.puts "models=\#{ctx.models_for_provider(:openai).map(&:id).include?('gpt-4o-mini')}"
          file.puts "system_reader=\#{ctx.get_system_prompt}"
        end
        "inspected \#{ctx.args_string}"
      end
    RUBY
    provider = StubProvider.new([StubProvider.text("should not be used")])
    agent = Truffle::Agent.new(provider: provider, model: model,
                               system_prompt: "Be precise",
                               session: session, extensions: extensions)

    assert_equal "inspected alpha beta", agent.run("/inspect alpha beta", signal: signal)
    assert_empty provider.calls
    assert_equal(
      [
        "args=alpha beta",
        "context=Truffle::Extensions::CommandContext",
        "command=inspect:inspect",
        "parsed=alpha|beta",
        "agent=Truffle::Agent",
        "provider=stub",
        "model=gpt-4o-mini",
        "model_spec=GPT-4o mini",
        "session_cwd=#{@dir}",
        "cwd=#{@dir}",
        "system=Be precise",
        "usage=0",
        "signal=Truffle::AbortSignal",
        "session_name=",
        "models=true",
        "system_reader=Be precise"
      ],
      File.readlines(log_path, chomp: true)
    )
  end

  def test_extension_command_context_exposes_provider_runtime_registry
    log_path = File.join(@dir, "provider_registry.log")
    extensions = load_extension(<<~RUBY)
      log_path = #{log_path.inspect}

      truffle.register_provider("local", {
        api: :openai_completions,
        base_url: "http://localhost:11434/v1",
        api_key: "test-key",
        models: [
          { id: "llama3", api: :openai_completions, input: ["text"] }
        ]
      })

      truffle.register_command("models", description: "Inspect models") do |_args, ctx|
        truffle.register_provider("dynamic", {
          api: :openai_completions,
          base_url: "http://dynamic.test/v1",
          api_key: "dynamic-key",
          model: "dyno"
        })

        registry = ctx.model_registry
        local = registry.resolve_model("local/llama3")
        dynamic = registry.resolve_model("dynamic/dyno")
        provider = registry.get_provider("LOCAL")

        File.open(log_path, "w") do |file|
          file.puts "registry=\#{registry.class.name}"
          file.puts "aliases=\#{ctx.provider_registry.equal?(registry)}:\#{ctx.providers.equal?(registry)}"
          file.puts "names=\#{registry.provider_names.join('|')}"
          file.puts "provider=\#{provider.name}:\#{provider.api}:\#{provider.model_ids.join('|')}"
          file.puts "local=\#{local.provider}/\#{local.model_id}/\#{local.input.join('|')}"
          file.puts "dynamic=\#{dynamic.provider}/\#{dynamic.model_id}"
        end

        "models listed"
      end
    RUBY
    provider = StubProvider.new([StubProvider.text("should not be used")])
    agent = Truffle::Agent.new(provider: provider, extensions: extensions)

    assert_equal "models listed", agent.run("/models")
    assert_empty provider.calls
    assert_empty Truffle.registered_provider_names
    assert_equal(
      [
        "registry=Truffle::ProviderRegistry::Collection",
        "aliases=true:true",
        "names=local|dynamic",
        "provider=local:openai_completions:llama3",
        "local=local/llama3/text",
        "dynamic=dynamic/dyno"
      ],
      File.readlines(log_path, chomp: true)
    )
  end

  def test_extension_command_can_set_session_display_name
    session = Truffle::Session.create(dir: File.join(@dir, "sessions"), cwd: @dir)
    extensions = load_extension(<<~'RUBY')
      truffle.register_command("name-session") do |args, ctx|
        "named #{ctx.set_session_name(args)}"
      end
    RUBY
    provider = StubProvider.new([StubProvider.text("should not be used")])
    agent = Truffle::Agent.new(provider: provider, session: session, extensions: extensions)

    assert_equal "named New Name", agent.run("/name-session  New Name  ")
    assert_equal "New Name", session.session_name
    assert_equal "New Name", Truffle::Session.load(session.file).session_name
    assert_empty provider.calls
  end

  def test_extension_command_session_actions_require_a_session
    extensions = load_extension(<<~RUBY)
      truffle.register_command("name-session") do |_args, ctx|
        ctx.set_session_name("missing")
      end
    RUBY
    agent = Truffle::Agent.new(provider: StubProvider.new([]), extensions: extensions)

    error = assert_raises(Truffle::Error) { agent.run("/name-session") }

    assert_match(/set_session_name requires a session-backed agent/, error.message)
  end

  def test_extension_command_can_trigger_manual_compaction
    session = Truffle::Session.create(dir: File.join(@dir, "sessions"), cwd: @dir)
    5.times do |index|
      session.append_message(Truffle::Message.user("user #{index}"))
      session.append_message(Truffle::Message.assistant(content: "assistant #{index}"))
    end
    session.flush
    extensions = load_extension(<<~'RUBY')
      truffle.register_command("compact-now") do |_args, ctx|
        "compacted=#{ctx.compact}"
      end
    RUBY
    provider = CompactingStub.new([], summary: "## Goal\nKeep going.")
    agent = Truffle::Agent.new(provider: provider, model: "claude-opus-4-5",
                               session: session, extensions: extensions)
    events = []
    agent.on(:compaction) { |payload| events << payload }

    assert_equal "compacted=true", agent.run("/compact-now")

    assert_equal 1, provider.summary_calls.length
    assert_equal 1, events.length
    assert(session.entries.any? { |entry| entry[:type] == "compaction" })
    assert_includes agent.messages.first.text, "compacted into the following summary"
    assert_empty provider.loop_calls
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

  def test_event_time_provider_registration_refreshes_next_provider_turn
    extensions = load_extension(<<~RUBY)
      truffle.register_provider("local", {
        api: :openai_completions,
        base_url: "http://first.test/v1",
        api_key: "first-key",
        model: "llama3"
      })

      truffle.on("agent_start") do
        truffle.register_provider("local", {
          api: :openai_completions,
          base_url: "http://second.test/v1",
          api_key: "second-key",
          model: "llama3"
        })
      end
    RUBY

    capture_openai_chat do |calls|
      agent = Truffle.agent(provider: :local, model: "llama3", extensions: extensions)

      assert_equal "http://first.test/v1", agent.provider.base_url
      assert_equal "done", agent.run("hello")

      assert_equal 1, calls.length
      assert_equal "http://second.test/v1", calls.first[:base_url]
      assert_equal "llama3", calls.first[:model]
      assert_equal "Bearer second-key", calls.first[:headers]["Authorization"]
      assert_equal "http://second.test/v1", agent.provider.base_url
    end
  end

  def test_command_time_provider_registration_refreshes_later_provider_turn
    extensions = load_extension(<<~RUBY)
      truffle.register_provider("local", {
        api: :openai_completions,
        base_url: "http://first.test/v1",
        api_key: "first-key",
        model: "llama3"
      })

      truffle.register_command("use-proxy") do
        truffle.register_provider("local", {
          api: :openai_completions,
          base_url: "http://command.test/v1",
          api_key: "command-key",
          model: "llama3"
        })
        "proxy ready"
      end
    RUBY

    capture_openai_chat do |calls|
      agent = Truffle.agent(provider: :local, model: "llama3", extensions: extensions)

      assert_equal "proxy ready", agent.run("/use-proxy")
      assert_empty calls

      assert_equal "done", agent.run("hello")

      assert_equal 1, calls.length
      assert_equal "http://command.test/v1", calls.first[:base_url]
      assert_equal "Bearer command-key", calls.first[:headers]["Authorization"]
      assert_equal "http://command.test/v1", agent.provider.base_url
    end
  end

  def test_command_time_provider_unregister_does_not_reuse_stale_extension_provider
    extensions = load_extension(<<~RUBY)
      truffle.register_provider("local", {
        api: :openai_completions,
        base_url: "http://first.test/v1",
        api_key: "first-key",
        model: "llama3"
      })

      truffle.register_command("remove-proxy") do
        truffle.unregister_provider("local")
        "proxy removed"
      end
    RUBY

    capture_openai_chat do |calls|
      agent = Truffle.agent(provider: :local, model: "llama3", extensions: extensions)

      assert_equal "proxy removed", agent.run("/remove-proxy")
      assert_empty calls

      error = assert_raises(Truffle::Error) { agent.run("hello") }

      assert_match(/extension provider "local" is no longer registered/, error.message)
      assert_empty calls
    end
  end

  def test_command_time_builtin_provider_unregister_restores_builtin_provider
    extensions = load_extension(<<~RUBY)
      truffle.register_provider("openai", {
        api: :openai_completions,
        base_url: "http://proxy.test/v1",
        api_key: "proxy-key",
        model: "gpt-4o-mini"
      })

      truffle.register_command("use-default-openai") do
        truffle.unregister_provider("openai")
        "default ready"
      end
    RUBY

    capture_openai_chat do |calls|
      agent = Truffle.agent(
        provider: :openai,
        model: "gpt-4o-mini",
        extensions: extensions,
        api_key: "builtin-key"
      )

      assert_equal "http://proxy.test/v1", agent.provider.base_url
      assert_equal "default ready", agent.run("/use-default-openai")
      assert_equal "done", agent.run("hello")

      assert_equal 1, calls.length
      assert_equal "https://api.openai.com/v1", calls.first[:base_url]
      assert_equal "Bearer builtin-key", calls.first[:headers]["Authorization"]
      assert_equal "gpt-4o-mini", calls.first[:model]
    end
  end

  def test_extension_handlers_observe_agent_events_in_order
    log_path = File.join(@dir, "events.log")
    extensions = load_extension(<<~RUBY)
      log_path = #{log_path.inspect}

      truffle.on("agent_start") do |event, ctx|
        File.open(log_path, "a") do |file|
          file.puts "agent_start:\#{event[:type]}:\#{event[:input]}:\#{ctx.nil?}"
        end
      end

      truffle.on("turn_start") do |event|
        File.open(log_path, "a") { |file| file.puts "turn_start:\#{event[:turn]}" }
      end

      truffle.on("message") do |event|
        File.open(log_path, "a") { |file| file.puts "message:\#{event[:message].text}" }
      end

      truffle.on("turn_end") do |event|
        File.open(log_path, "a") { |file| file.puts "turn_end:\#{event[:turn]}" }
      end

      truffle.on("agent_end") do |event, ctx|
        File.open(log_path, "a") do |file|
          file.puts "agent_end:\#{event[:output]}:\#{ctx.nil?}"
        end
      end
    RUBY
    provider = StubProvider.new([StubProvider.text("done")])
    agent = Truffle::Agent.new(provider: provider, extensions: extensions)

    assert_equal "done", agent.run("hello")
    assert_equal(
      [
        "agent_start:agent_start:hello:false",
        "turn_start:1",
        "message:done",
        "turn_end:1",
        "agent_end:done:false"
      ],
      File.readlines(log_path, chomp: true)
    )
  end

  def test_extension_handlers_receive_runtime_context
    log_path = File.join(@dir, "context.log")
    session = Truffle::Session.create(dir: File.join(@dir, "sessions"), cwd: @dir)
    model = Truffle::Models.find("gpt-4o-mini")
    signal = Truffle::AbortSignal.new
    extensions = load_extension(<<~RUBY)
      log_path = #{log_path.inspect}

      truffle.on("agent_start") do |event, ctx|
        File.open(log_path, "w") do |file|
          file.puts "event=\#{event[:type]}"
          file.puts "agent=\#{ctx.agent.class.name}"
          file.puts "provider=\#{ctx.provider.name}"
          file.puts "model=\#{ctx.model}"
          file.puts "model_spec=\#{ctx.model_spec.name}"
          file.puts "session_cwd=\#{ctx.session.cwd}"
          file.puts "cwd=\#{ctx.cwd}"
          file.puts "system=\#{ctx.system_prompt}"
          file.puts "usage=\#{ctx.context_usage.input}"
          file.puts "signal=\#{ctx.signal.class.name}"
          file.puts "mode=\#{ctx.mode}"
          file.puts "idle=\#{ctx.idle?}"
          file.puts "ui=\#{ctx.ui?}:\#{ctx.ui.nil?}"
          file.puts "trusted=\#{ctx.project_trusted?}"
          file.puts "pending=\#{ctx.pending_messages?}"
        end
      end
    RUBY
    provider = StubProvider.new([StubProvider.text("done")])
    agent = Truffle::Agent.new(provider: provider, model: model,
                               system_prompt: "Be precise",
                               session: session, extensions: extensions)

    assert_equal "done", agent.run("hello", signal: signal)
    assert_equal(
      [
        "event=agent_start",
        "agent=Truffle::Agent",
        "provider=stub",
        "model=gpt-4o-mini",
        "model_spec=GPT-4o mini",
        "session_cwd=#{@dir}",
        "cwd=#{@dir}",
        "system=Be precise",
        "usage=0",
        "signal=Truffle::AbortSignal",
        "mode=print",
        "idle=false",
        "ui=false:true",
        "trusted=false",
        "pending=false"
      ],
      File.readlines(log_path, chomp: true)
    )
  end

  def test_extension_event_context_exposes_provider_runtime_registry
    log_path = File.join(@dir, "event_provider_registry.log")
    extensions = load_extension(<<~RUBY)
      log_path = #{log_path.inspect}

      truffle.register_provider("events", {
        api: :openai_completions,
        base_url: "http://events.test/v1",
        api_key: "events-key",
        models: [
          { id: "event-model", api: :openai_completions, input: ["text"] }
        ]
      })

      truffle.on("agent_start") do |_event, ctx|
        registry = ctx.model_registry
        model = registry.get_model("events", "event-model")

        File.open(log_path, "w") do |file|
          file.puts "aliases=\#{ctx.provider_registry.equal?(registry)}:\#{ctx.providers.equal?(registry)}"
          file.puts "names=\#{registry.provider_names.join('|')}"
          file.puts "model=\#{model.provider}/\#{model.model_id}/\#{model.input.join('|')}"
        end
      end
    RUBY
    provider = StubProvider.new([StubProvider.text("done")])
    agent = Truffle::Agent.new(provider: provider, extensions: extensions)

    assert_equal "done", agent.run("hello")
    assert_equal(
      [
        "aliases=true:true",
        "names=events",
        "model=events/event-model/text"
      ],
      File.readlines(log_path, chomp: true)
    )
  end

  def test_extension_handlers_observe_tool_events
    log_path = File.join(@dir, "tool_events.log")
    extensions = load_extension(<<~RUBY)
      log_path = #{log_path.inspect}

      tool = Truffle.tool("echo", "Echo") do
        param :value, :string, required: true
        run { |value:| value }
      end
      truffle.register_tool(tool)

      truffle.on("tool_call") do |event|
        File.open(log_path, "a") { |file| file.puts "call:\#{event[:call].name}" }
      end

      truffle.on("tool_result") do |event|
        File.open(log_path, "a") { |file| file.puts "result:\#{event[:result]}" }
      end
    RUBY
    provider = StubProvider.new([
                                  StubProvider.tool_call(id: "c1", name: "echo",
                                                         arguments: { "value" => "seen" }),
                                  StubProvider.text("done")
                                ])
    agent = Truffle::Agent.new(provider: provider, extensions: extensions)

    agent.run("echo")

    assert_equal ["call:echo", "result:seen"], File.readlines(log_path, chomp: true)
  end

  def test_extension_handler_errors_are_isolated_and_recorded
    log_path = File.join(@dir, "errors.log")
    extensions = load_extension(<<~RUBY)
      log_path = #{log_path.inspect}

      truffle.on("agent_start") { raise "boom" }
      truffle.on("agent_start") do |event|
        File.write(log_path, event[:input])
      end
    RUBY
    provider = StubProvider.new([StubProvider.text("done")])
    agent = Truffle::Agent.new(provider: provider, extensions: extensions)

    assert_equal "done", agent.run("hello")
    assert_equal "hello", File.read(log_path)

    error = agent.extension_errors.fetch(0)

    assert_equal "agent_start", error.event
    assert_equal extensions.extensions.first.path, error.extension_path
    assert_match(/RuntimeError: boom/, error.error)
  end

  def test_extension_handler_accepts_one_arg_lambdas
    log_path = File.join(@dir, "lambda.log")
    extensions = load_extension(<<~RUBY)
      log_path = #{log_path.inspect}
      truffle.on("agent_start", ->(event) { File.write(log_path, event[:input]) })
    RUBY
    provider = StubProvider.new([StubProvider.text("done")])
    agent = Truffle::Agent.new(provider: provider, extensions: extensions)

    assert_equal "done", agent.run("hello")
    assert_equal "hello", File.read(log_path)
    assert_empty agent.extension_errors
  end
end
