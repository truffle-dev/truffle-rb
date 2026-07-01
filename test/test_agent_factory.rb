# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "tmpdir"
require "fileutils"

# Tests for the Truffle.agent convenience constructor, focused on provider
# resolution: naming a catalog model is enough, the provider is inferred. An
# api_key is passed through so the inferred provider builds without touching the
# network (no #run is called, so nothing dials out).
class AgentFactoryTest < Minitest::Test
  def agent_model(agent) = agent.instance_variable_get(:@model)
  def retry_settings(agent) = agent.instance_variable_get(:@retry_settings)
  def compaction_settings(agent) = agent.instance_variable_get(:@compaction_settings)

  def with_project_settings(value)
    Dir.mktmpdir("truffle-agent-settings") do |dir|
      FileUtils.mkdir_p(File.join(dir, ".truffle"))
      File.write(File.join(dir, ".truffle", "settings.json"), "#{JSON.pretty_generate(value)}\n")
      yield dir
    end
  end

  def test_inferred_provider_from_a_bare_model_id
    agent = Truffle.agent(model: "claude-opus-4-8", api_key: "k")

    assert_instance_of Truffle::Providers::Anthropic, agent.provider
    assert_equal "claude-opus-4-8", agent_model(agent)
  end

  def test_inferred_provider_routes_each_family
    openai = Truffle.agent(model: "gpt-4o", api_key: "k")
    google = Truffle.agent(model: "gemini-2.5-pro", api_key: "k")

    assert_instance_of Truffle::Providers::OpenAI, openai.provider
    assert_instance_of Truffle::Providers::Google, google.provider
  end

  def test_canonical_reference_reduces_to_the_bare_wire_id
    agent = Truffle.agent(model: "anthropic/claude-opus-4-8", api_key: "k")

    assert_instance_of Truffle::Providers::Anthropic, agent.provider
    # The provider expects its own id, not the "provider/id" reference.
    assert_equal "claude-opus-4-8", agent_model(agent)
  end

  def test_explicit_provider_is_left_untouched_for_custom_model_ids
    # A model id not in the catalog still works when the provider is named; the
    # factory must not try to resolve or rewrite it.
    agent = Truffle.agent(provider: :openai, model: "ft:gpt-4o:acme:custom", api_key: "k")

    assert_instance_of Truffle::Providers::OpenAI, agent.provider
    assert_equal "ft:gpt-4o:acme:custom", agent_model(agent)
  end

  def test_no_provider_and_no_model_raises
    error = assert_raises(Truffle::Error) { Truffle.agent }

    assert_match(/provider:/, error.message)
  end

  def test_unresolvable_model_without_a_provider_raises
    error = assert_raises(Truffle::Error) { Truffle.agent(model: "no-such-model") }

    assert_match(/cannot infer a provider/, error.message)
  end

  def test_project_settings_supply_default_provider_and_model
    with_project_settings(
      "defaultProvider" => "openai",
      "defaultModel" => "gpt-4o-mini"
    ) do |dir|
      agent = Truffle.agent(cwd: dir, api_key: "k")

      assert_instance_of Truffle::Providers::OpenAI, agent.provider
      assert_equal "gpt-4o-mini", agent_model(agent)
    end
  end

  def test_project_settings_can_infer_provider_from_default_model
    with_project_settings("defaultModel" => "claude-opus-4-8") do |dir|
      agent = Truffle.agent(cwd: dir, api_key: "k")

      assert_instance_of Truffle::Providers::Anthropic, agent.provider
      assert_equal "claude-opus-4-8", agent_model(agent)
    end
  end

  def test_explicit_provider_and_model_override_project_settings
    with_project_settings(
      "defaultProvider" => "anthropic",
      "defaultModel" => "claude-opus-4-8"
    ) do |dir|
      agent = Truffle.agent(cwd: dir, provider: :openai, model: "gpt-4o", api_key: "k")

      assert_instance_of Truffle::Providers::OpenAI, agent.provider
      assert_equal "gpt-4o", agent_model(agent)
    end
  end

  def test_settings_false_skips_project_settings
    with_project_settings("defaultProvider" => "openai") do |dir|
      error = assert_raises(Truffle::Error) do
        Truffle.agent(cwd: dir, settings: false, api_key: "k")
      end

      assert_match(/provider:/, error.message)
    end
  end

  def test_project_settings_feed_retry_and_compaction_defaults
    with_project_settings(
      "defaultProvider" => "openai",
      "defaultModel" => "gpt-4o-mini",
      "compaction" => { "enabled" => false, "reserveTokens" => 123, "keepRecentTokens" => 45 },
      "retry" => { "enabled" => false, "maxRetries" => 1, "baseDelayMs" => 0, "maxDelayMs" => 10 }
    ) do |dir|
      agent = Truffle.agent(cwd: dir, api_key: "k")

      refute compaction_settings(agent).enabled
      assert_equal 123, compaction_settings(agent).reserve_tokens
      assert_equal 45, compaction_settings(agent).keep_recent_tokens
      assert_equal({
                     enabled: false,
                     max_retries: 1,
                     base_delay_ms: 0,
                     max_delay_ms: 10
                   }, retry_settings(agent))
    end
  end
end
