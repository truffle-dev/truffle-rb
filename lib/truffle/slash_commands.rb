# frozen_string_literal: true

module Truffle
  # Slash-command registry, ported from pi's slash command surface. Prompt
  # commands expand into user text before the provider sees a turn; handler
  # commands run locally and do not consume a provider response. Built-in commands
  # are listed for UI/help surfaces, but their TUI actions are out of scope here.
  module SlashCommands
    Command = Struct.new(:name, :description, :source, :handler, :template,
                         :invocation_name, keyword_init: true)
    Result = Struct.new(:type, :command, :args_string, :args, :content,
                        keyword_init: true)

    BUILTIN_COMMANDS = [
      ["settings", "Open settings menu"],
      ["model", "Select model (opens selector UI)"],
      ["scoped-models", "Enable/disable models for Ctrl+P cycling"],
      ["export", "Export session (HTML default, or specify path: .html/.jsonl)"],
      ["import", "Import and resume a session from a JSONL file"],
      ["share", "Share session as a secret GitHub gist"],
      ["copy", "Copy last agent message to clipboard"],
      ["name", "Set session display name"],
      ["session", "Show session info and stats"],
      ["changelog", "Show changelog entries"],
      ["hotkeys", "Show all keyboard shortcuts"],
      ["fork", "Create a new fork from a previous user message"],
      ["clone", "Duplicate the current session at the current position"],
      ["tree", "Navigate session tree (switch branches)"],
      ["trust", "Save project trust decision for future sessions"],
      ["login", "Configure provider authentication"],
      ["logout", "Remove provider authentication"],
      ["new", "Start a new session"],
      ["compact", "Manually compact the session context"],
      ["resume", "Resume a different session"],
      ["reload", "Reload keybindings, extensions, skills, prompts, and themes"],
      ["quit", "Quit Truffle"]
    ].map do |name, description|
      Command.new(name: name, description: description, source: :builtin,
                  invocation_name: name)
    end.freeze

    class Registry
      attr_reader :commands

      def initialize(prompt_templates: [], commands: [])
        @commands = []
        @counts = Hash.new(0)
        prompt_templates.each { |template| register_prompt(template) }
        commands.each { |command| add(command) }
      end

      def empty?
        @commands.empty?
      end

      def register_prompt(template)
        add(Command.new(
              name: template.name,
              description: template.description,
              source: :prompt,
              template: template
            ))
      end

      def register(name, description: nil, source: :extension, &handler)
        raise ArgumentError, "slash command handler required" unless handler

        add(Command.new(
              name: name.to_s,
              description: description,
              source: source.to_sym,
              handler: handler
            ))
      end

      def get(invocation_name)
        @commands.find { |command| command.invocation_name == invocation_name }
      end

      def resolve(text, context: nil)
        parsed = parse(text)
        return nil unless parsed

        command = get(parsed[:name])
        return nil unless command

        args = PromptTemplates.parse_command_args(parsed[:args_string])
        command_context = build_command_context(context, command, parsed[:args_string], args)
        case command.source
        when :prompt
          Result.new(
            type: :prompt,
            command: command,
            args_string: parsed[:args_string],
            args: args,
            content: PromptTemplates.substitute_args(command.template.content, args)
          )
        else
          Result.new(
            type: :action,
            command: command,
            args_string: parsed[:args_string],
            args: args,
            content: call_handler(command.handler, parsed[:args_string], command_context)
          )
        end
      end

      private

      def add(command)
        command.name = command.name.to_s
        assign_invocation_name(command)
        @commands << command
        command
      end

      def parse(text)
        return nil unless text.start_with?("/")

        match = text.match(%r{\A/([^\s]+)(?:\s+([\s\S]*))?\z})
        return nil unless match

        { name: match[1], args_string: match[2] || "" }
      end

      def assign_invocation_name(command)
        @counts[command.name] += 1
        count = @counts[command.name]
        if count == 1
          command.invocation_name = command.name
        else
          first = @commands.find { |existing| existing.name == command.name }
          first.invocation_name = "#{command.name}:1" if first&.invocation_name == command.name
          command.invocation_name = "#{command.name}:#{count}"
        end
      end

      def build_command_context(context, command, args_string, args)
        return context unless context.respond_to?(:with_command)

        context.with_command(command: command, args_string: args_string, args: args)
      end

      def call_handler(handler, args_string, context)
        case handler.arity
        when 0
          handler.call
        when 1, -1
          handler.call(args_string)
        else
          handler.call(args_string, context)
        end
      end
    end
  end
end
