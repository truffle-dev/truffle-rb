# frozen_string_literal: true

require_relative "test_helper"

# Tests for the Truffle.agent convenience constructor, focused on provider
# resolution: naming a catalog model is enough, the provider is inferred. An
# api_key is passed through so the inferred provider builds without touching the
# network (no #run is called, so nothing dials out).
class AgentFactoryTest < Minitest::Test
  def agent_model(agent) = agent.instance_variable_get(:@model)

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
end
