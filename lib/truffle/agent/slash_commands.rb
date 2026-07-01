# frozen_string_literal: true

module Truffle
  # Slash-command helpers for Agent, kept out of agent.rb so the main loop stays
  # readable. Prompt commands rewrite the user input before the provider turn;
  # handler commands finish locally without touching message history.
  class Agent
    private

    def slash_registry_for(prompt_templates, slash_commands: nil, extensions: nil)
      commands = []
      commands.concat(slash_commands.commands.map(&:dup)) if slash_commands
      commands.concat(Extensions.command_definitions(extensions).map(&:dup))
      return nil if Array(prompt_templates).empty? && commands.empty?

      SlashCommands::Registry.new(prompt_templates: prompt_templates, commands: commands)
    end

    def resolve_slash_command(user_input)
      @slash_commands&.resolve(user_input, context: extension_event_context)
    end

    def run_slash_action(result)
      emit(:agent_start, input: "/#{result.command.invocation_name} #{result.args_string}".strip)
      emit(:agent_end, output: result.content, messages: @messages,
                       stop_reason: StopReason::STOP, error_message: nil, usage: @usage)
      result.content
    end
  end
end
