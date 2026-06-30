# frozen_string_literal: true

require "test_helper"

class TestAgentSlashCommands < Minitest::Test
  Template = Truffle::PromptTemplates::Template
  Registry = Truffle::SlashCommands::Registry

  def test_agent_expands_prompt_template_before_provider_turn
    template = Template.new(
      name: "review",
      description: "Review",
      content: "Review this file: $1"
    )
    provider = StubProvider.new([StubProvider.text("ok")])
    agent = Truffle::Agent.new(provider: provider, prompt_templates: [template])

    agent.run("/review lib/truffle.rb")

    user = provider.calls.first[:messages].find { |message| message[:role] == :user }

    assert_equal "Review this file: lib/truffle.rb", user[:content].first[:text]
  end

  def test_agent_dispatches_handler_command_without_provider_turn
    registry = Registry.new
    registry.register("reload", description: "Reload") { |args| "reloaded #{args}" }
    provider = StubProvider.new([StubProvider.text("should not be used")])
    agent = Truffle::Agent.new(provider: provider, slash_commands: registry)
    events = []
    agent.on { |type, payload| events << [type, payload] }

    result = agent.run("/reload prompts")

    assert_equal "reloaded prompts", result
    assert_empty provider.calls
    assert_empty agent.messages
    assert_equal %i[agent_start agent_end], events.map(&:first)
    assert_equal "reloaded prompts", events.last.last[:output]
  end

  def test_unknown_slash_command_is_sent_as_plain_user_text
    provider = StubProvider.new([StubProvider.text("ok")])
    agent = Truffle::Agent.new(provider: provider, slash_commands: Registry.new)

    agent.run("/unknown keep this")

    user = provider.calls.first[:messages].find { |message| message[:role] == :user }

    assert_equal "/unknown keep this", user[:content].first[:text]
  end
end
