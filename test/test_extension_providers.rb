# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

# Provider registrations are data until the public factories bind them. This
# covers the first provider binding slice: OpenAI-compatible registrations can
# back Truffle.provider and Truffle.agent without mutating the global catalog.
class TestExtensionProviders < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("truffle-extension-providers")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def write_extension(name, body)
    path = File.join(@dir, name)
    File.write(path, body)
    path
  end

  def load_extensions(*bodies)
    paths = bodies.each_with_index.map do |body, index|
      write_extension("ext#{index}.rb", body)
    end
    Truffle::Extensions.load_files(paths)
  end

  def agent_model(agent) = agent.instance_variable_get(:@model)

  def registered_local_provider
    load_extensions(<<~RUBY)
      truffle.register_provider("local", {
        api: :openai_completions,
        base_url: "http://localhost:11434/v1",
        api_key: "test-key",
        models: [
          { id: "llama3", name: "Llama 3", api: :openai_completions }
        ]
      })
    RUBY
  end

  def test_truffle_provider_builds_registered_openai_compatible_provider
    provider = Truffle.provider(:local, extensions: registered_local_provider)

    assert_instance_of Truffle::Providers::OpenAI, provider
    assert_equal "local", provider.name
    assert_equal "llama3", provider.model
    assert_equal "http://localhost:11434/v1", provider.base_url
  end

  def test_caller_options_override_registered_provider_options
    provider = Truffle.provider(
      :local,
      extensions: registered_local_provider,
      base_url: "http://override.test/v1",
      model: "override-model"
    )

    assert_equal "http://override.test/v1", provider.base_url
    assert_equal "override-model", provider.model
  end

  def test_later_provider_registration_overrides_defined_values
    extensions = load_extensions(
      <<~RUBY,
        truffle.register_provider("local", {
          api: :openai_completions,
          base_url: "http://first.test/v1",
          api_key: "test-key",
          models: [{ id: "first-model", api: :openai_completions }]
        })
      RUBY
      <<~RUBY
        truffle.register_provider("LOCAL", {
          baseUrl: "http://second.test/v1"
        })
      RUBY
    )

    provider = Truffle.provider(:local, extensions: extensions)

    assert_equal "local", provider.name
    assert_equal "http://second.test/v1", provider.base_url
    assert_equal "first-model", provider.model
  end

  def test_truffle_agent_infers_registered_provider_from_canonical_model_reference
    agent = Truffle.agent(model: "local/llama3", extensions: registered_local_provider)

    assert_equal "local", agent.provider.name
    assert_equal "llama3", agent_model(agent)
  end

  def test_truffle_agent_infers_registered_provider_from_unique_bare_model
    agent = Truffle.agent(model: "llama3", extensions: registered_local_provider)

    assert_equal "local", agent.provider.name
    assert_equal "llama3", agent_model(agent)
  end

  def test_ambiguous_registered_bare_model_requires_provider_reference
    extensions = load_extensions(
      <<~RUBY,
        truffle.register_provider("one", {
          api: :openai_completions,
          base_url: "http://one.test/v1",
          api_key: "test-key",
          models: [{ id: "shared", api: :openai_completions }]
        })
      RUBY
      <<~RUBY
        truffle.register_provider("two", {
          api: :openai_completions,
          base_url: "http://two.test/v1",
          api_key: "test-key",
          models: [{ id: "shared", api: :openai_completions }]
        })
      RUBY
    )

    error = assert_raises(Truffle::Error) do
      Truffle.agent(model: "shared", extensions: extensions)
    end

    assert_match(/cannot infer a provider/, error.message)
  end

  def test_unsupported_registered_provider_api_raises
    extensions = load_extensions(<<~RUBY)
      truffle.register_provider("corp", {
        api: :anthropic_messages,
        base_url: "http://corp.test/v1",
        api_key: "test-key",
        models: [{ id: "claude", api: :anthropic_messages }]
      })
    RUBY

    error = assert_raises(Truffle::Error) { Truffle.provider(:corp, extensions: extensions) }

    assert_match(/unsupported api/, error.message)
  end

  def test_provider_api_key_can_come_from_environment_reference
    old_value = ENV.fetch("TRUFFLE_TEST_EXTENSION_PROVIDER_KEY", nil)
    ENV["TRUFFLE_TEST_EXTENSION_PROVIDER_KEY"] = "env-key"
    extensions = load_extensions(<<~RUBY)
      truffle.register_provider("local", {
        api: :openai_completions,
        base_url: "http://localhost:11434/v1",
        api_key: "$TRUFFLE_TEST_EXTENSION_PROVIDER_KEY",
        model: "llama3"
      })
    RUBY

    provider = Truffle.provider(:local, extensions: extensions)

    assert_equal({ "Authorization" => "Bearer env-key" }, provider.send(:stream_request_headers))
  ensure
    if old_value.nil?
      ENV.delete("TRUFFLE_TEST_EXTENSION_PROVIDER_KEY")
    else
      ENV["TRUFFLE_TEST_EXTENSION_PROVIDER_KEY"] = old_value
    end
  end

  def test_provider_headers_are_resolved_for_chat_and_stream_requests
    old_value = ENV.fetch("TRUFFLE_TEST_EXTENSION_HEADER_TOKEN", nil)
    ENV["TRUFFLE_TEST_EXTENSION_HEADER_TOKEN"] = "secret-token"
    extensions = load_extensions(<<~RUBY)
      truffle.register_provider("local", {
        api: :openai_completions,
        base_url: "http://localhost:11434/v1",
        authHeader: false,
        model: "llama3",
        headers: {
          "Authorization" => "Bearer $TRUFFLE_TEST_EXTENSION_HEADER_TOKEN",
          "X-Tenant" => "acme",
          "X-Escaped" => "cost $$1 $!bang"
        }
      })
    RUBY

    provider = Truffle.provider(:local, extensions: extensions)

    chat_headers = provider.send(:request_headers)

    assert_equal "application/json", chat_headers["Content-Type"]
    assert_equal "Bearer secret-token", chat_headers["Authorization"]
    assert_equal "acme", chat_headers["X-Tenant"]
    assert_equal "cost $1 !bang", chat_headers["X-Escaped"]

    stream_request = provider.send(:build_stream_request, URI("http://localhost:11434/v1/chat"), {})

    assert_equal "text/event-stream", stream_request["Accept"]
    assert_equal "Bearer secret-token", stream_request["Authorization"]
    assert_equal "acme", stream_request["X-Tenant"]
  ensure
    if old_value.nil?
      ENV.delete("TRUFFLE_TEST_EXTENSION_HEADER_TOKEN")
    else
      ENV["TRUFFLE_TEST_EXTENSION_HEADER_TOKEN"] = old_value
    end
  end

  def test_auth_header_generates_authorization_after_custom_headers
    extensions = load_extensions(<<~RUBY)
      truffle.register_provider("local", {
        api: :openai_completions,
        base_url: "http://localhost:11434/v1",
        api_key: "test-key",
        auth_header: true,
        model: "llama3",
        headers: {
          "Authorization" => "Bearer custom",
          "X-Tenant" => "acme"
        }
      })
    RUBY

    provider = Truffle.provider(:local, extensions: extensions)
    headers = provider.send(:request_headers)

    assert_equal "Bearer test-key", headers["Authorization"]
    assert_equal "acme", headers["X-Tenant"]
  end

  def test_caller_headers_merge_over_registered_provider_headers
    extensions = load_extensions(<<~RUBY)
      truffle.register_provider("local", {
        api: :openai_completions,
        base_url: "http://localhost:11434/v1",
        auth_header: false,
        model: "llama3",
        headers: {
          "Authorization" => "Bearer extension",
          "X-Keep" => "extension",
          "X-Override" => "extension"
        }
      })
    RUBY

    provider = Truffle.provider(
      :local,
      extensions: extensions,
      headers: {
        "Authorization" => "Bearer caller",
        "X-Override" => "caller",
        "X-New" => "caller"
      }
    )
    headers = provider.send(:request_headers)

    assert_equal "Bearer caller", headers["Authorization"]
    assert_equal "extension", headers["X-Keep"]
    assert_equal "caller", headers["X-Override"]
    assert_equal "caller", headers["X-New"]
  end

  def test_missing_header_environment_reference_raises
    old_value = ENV.fetch("TRUFFLE_TEST_MISSING_EXTENSION_HEADER", nil)
    ENV.delete("TRUFFLE_TEST_MISSING_EXTENSION_HEADER")
    extensions = load_extensions(<<~RUBY)
      truffle.register_provider("local", {
        api: :openai_completions,
        base_url: "http://localhost:11434/v1",
        auth_header: false,
        model: "llama3",
        headers: {
          "Authorization" => "Bearer $TRUFFLE_TEST_MISSING_EXTENSION_HEADER"
        }
      })
    RUBY

    error = assert_raises(Truffle::Error) do
      Truffle.provider(:local, extensions: extensions)
    end

    assert_match(/unresolved header Authorization environment reference/, error.message)
  ensure
    if old_value.nil?
      ENV.delete("TRUFFLE_TEST_MISSING_EXTENSION_HEADER")
    else
      ENV["TRUFFLE_TEST_MISSING_EXTENSION_HEADER"] = old_value
    end
  end

  def test_load_result_runtime_registrations_respect_unregister_across_files
    extensions = load_extensions(
      <<~RUBY,
        truffle.register_provider("local", {
          api: :openai_completions,
          base_url: "http://first.test/v1",
          api_key: "test-key",
          model: "first-model"
        })
      RUBY
      <<~RUBY
        truffle.unregister_provider("local")
      RUBY
    )

    error = assert_raises(Truffle::Error) do
      Truffle.provider(:local, extensions: extensions)
    end

    assert_match(/unknown provider/, error.message)
  end
end
