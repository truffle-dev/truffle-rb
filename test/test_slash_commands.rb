# frozen_string_literal: true

require "test_helper"

class TestSlashCommands < Minitest::Test
  Registry = Truffle::SlashCommands::Registry
  Template = Truffle::PromptTemplates::Template

  def test_builtin_command_info_is_available_for_ui_surfaces
    commands = Truffle::SlashCommands::BUILTIN_COMMANDS
    names = commands.map(&:name)

    assert_includes names, "model"
    assert_includes names, "quit"
    assert_equal "model", commands.find { |command| command.name == "model" }.invocation_name
  end

  def test_prompt_command_expands_template_arguments
    template = Template.new(
      name: "review",
      description: "Review code",
      content: "Review $1 with $@"
    )
    registry = Registry.new(prompt_templates: [template])

    result = registry.resolve(%(/review "lib/truffle.rb" carefully))

    assert_equal :prompt, result.type
    assert_equal "review", result.command.invocation_name
    assert_equal ["lib/truffle.rb", "carefully"], result.args
    assert_equal "Review lib/truffle.rb with lib/truffle.rb carefully", result.content
  end

  def test_unknown_or_plain_text_returns_nil
    registry = Registry.new

    assert_nil registry.resolve("plain text")
    assert_nil registry.resolve("/missing args")
  end

  def test_handler_command_receives_raw_argument_string
    seen = nil
    registry = Registry.new
    registry.register("deploy", description: "Deploy") do |args|
      seen = args
      "queued #{args}"
    end

    result = registry.resolve("/deploy production now")

    assert_equal :action, result.type
    assert_equal "production now", seen
    assert_equal %w[production now], result.args
    assert_equal "queued production now", result.content
  end

  def test_duplicate_handler_commands_get_invocation_suffixes
    registry = Registry.new
    registry.register("deploy", description: "first") { "first" }
    registry.register("deploy", description: "second") { "second" }

    assert_equal %w[deploy:1 deploy:2], registry.commands.map(&:invocation_name)
    assert_equal "first", registry.resolve("/deploy:1").content
    assert_equal "second", registry.resolve("/deploy:2").content
    assert_nil registry.resolve("/deploy")
  end
end
