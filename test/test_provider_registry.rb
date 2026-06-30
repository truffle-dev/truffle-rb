# frozen_string_literal: true

require_relative "test_helper"

# Programmatic OpenAI-compatible providers use the same normalized config path
# as extension registrations, without writing a Ruby extension file to disk.
class TestProviderRegistry < Minitest::Test
  def setup
    Truffle::ProviderRegistry.clear
  end

  def teardown
    Truffle::ProviderRegistry.clear
  end

  def register_local_provider
    Truffle.register_provider(
      "local",
      api: :openai_completions,
      base_url: "http://localhost:11434/v1",
      api_key: "test-key",
      models: [
        { id: "llama3", api: :openai_completions }
      ]
    )
  end

  def agent_model(agent) = agent.instance_variable_get(:@model)

  def test_truffle_provider_builds_registered_provider_without_extension_file
    register_local_provider

    provider = Truffle.provider(:local)

    assert_instance_of Truffle::Providers::OpenAI, provider
    assert_equal "local", provider.name
    assert_equal "llama3", provider.model
    assert_equal "http://localhost:11434/v1", provider.base_url
  end

  def test_caller_options_override_registered_options_and_merge_headers
    Truffle.register_provider(
      "local",
      api: :openai_completions,
      base_url: "http://first.test/v1",
      model: "llama3",
      auth_header: false,
      headers: {
        "Authorization" => "Bearer registered",
        "X-Keep" => "registered",
        "X-Override" => "registered"
      }
    )

    provider = Truffle.provider(
      "local",
      base_url: "http://override.test/v1",
      model: "override-model",
      headers: {
        "Authorization" => "Bearer caller",
        "X-Override" => "caller",
        "X-New" => "caller"
      }
    )
    headers = provider.send(:request_headers)

    assert_equal "http://override.test/v1", provider.base_url
    assert_equal "override-model", provider.model
    assert_equal "Bearer caller", headers["Authorization"]
    assert_equal "registered", headers["X-Keep"]
    assert_equal "caller", headers["X-Override"]
    assert_equal "caller", headers["X-New"]
  end

  def test_later_registration_overrides_defined_values
    Truffle.register_provider(
      "local",
      api: :openai_completions,
      base_url: "http://first.test/v1",
      api_key: "test-key",
      models: [{ id: "first-model", api: :openai_completions }]
    )
    Truffle.register_provider("LOCAL", baseUrl: "http://second.test/v1")

    provider = Truffle.provider(:local)

    assert_equal "local", provider.name
    assert_equal "http://second.test/v1", provider.base_url
    assert_equal "first-model", provider.model
  end

  def test_agent_infers_registered_provider_from_model_reference
    register_local_provider

    agent = Truffle.agent(model: "local/llama3")

    assert_equal "local", agent.provider.name
    assert_equal "llama3", agent_model(agent)
  end

  def test_agent_infers_registered_provider_from_unique_bare_model
    register_local_provider

    agent = Truffle.agent(model: "llama3")

    assert_equal "local", agent.provider.name
    assert_equal "llama3", agent_model(agent)
  end

  def test_extension_registration_wins_over_process_registry_for_same_provider
    register_local_provider
    extension = Truffle::Extensions::Extension.new(
      path: nil,
      resolved_path: nil,
      handlers: {},
      tools: {},
      commands: {},
      provider_registrations: [
        Truffle::Extensions::ProviderRegistration.new(
          name: "local",
          config: {
            api: :openai_completions,
            base_url: "http://extension.test/v1",
            model: "extension-model"
          },
          source_path: nil
        )
      ]
    )

    provider = Truffle.provider(:local, extensions: extension)

    assert_equal "http://extension.test/v1", provider.base_url
    assert_equal "extension-model", provider.model
  end

  def test_unregister_removes_registered_provider
    register_local_provider

    Truffle.unregister_provider("LOCAL")

    error = assert_raises(Truffle::Error) { Truffle.provider(:local) }
    assert_match(/unknown provider/, error.message)
  end

  def test_unknown_provider_message_includes_registered_names
    register_local_provider

    error = assert_raises(Truffle::Error) { Truffle.provider(:missing) }

    assert_match(/local/, error.message)
  end

  def test_registered_provider_names_reports_effective_names
    register_local_provider
    Truffle.register_provider("LOCAL", baseUrl: "http://second.test/v1")

    assert_equal ["local"], Truffle.registered_provider_names
  end
end
