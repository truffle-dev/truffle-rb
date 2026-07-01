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
