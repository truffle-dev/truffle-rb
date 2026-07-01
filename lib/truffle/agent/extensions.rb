# frozen_string_literal: true

module Truffle
  # Extension helpers for Agent, kept out of agent.rb so the main loop stays
  # readable. Loaded extension tools are defaults; application tools win on name
  # conflicts.
  class Agent
    # Build the toolbox a resumed agent runs with, checking that every tool the
    # dumped agent relied on is among the ones supplied now. The session stores
    # only names; the implementations are rebound here. A required tool that was
    # not supplied is an error, not a silent gap, since the model may call it.
    def self.rebind_toolbox(required_names, supplied, extensions: nil)
      toolbox = Toolbox.new(Extensions.tool_definitions(extensions))
      supplied_tools = supplied.is_a?(Toolbox) ? supplied : Toolbox.new(supplied)
      supplied_tools.each { |tool| toolbox.add(tool) }
      missing = Array(required_names) - toolbox.names
      unless missing.empty?
        raise Error, "session needs tool(s) not supplied to load: #{missing.join(", ")}"
      end

      toolbox
    end
    private_class_method :rebind_toolbox

    private

    def toolbox_for(tools, extensions)
      toolbox = Toolbox.new(Extensions.tool_definitions(extensions))
      supplied = tools.is_a?(Toolbox) ? tools : Toolbox.new(tools)
      supplied.each { |tool| toolbox.add(tool) }
      toolbox
    end

    def setup_extensions(source, provider, provider_name, provider_overrides)
      @extension_source = source
      @extensions = Extensions.loaded(source)
      @extension_errors = []
      @extension_provider_name =
        provider_name&.to_s || default_extension_provider_name(provider)
      @extension_provider_overrides = provider_overrides || {}
      @extension_provider_initial_options =
        Extensions.provider_options(@extension_source, @extension_provider_name)
      @extension_provider_initial_provider = provider
      @extension_provider_signature = current_extension_provider_signature
    end

    def dispatch_extension_handlers(event, payload)
      errors = Extensions.dispatch_handlers(@extensions, event, payload)
      @extension_errors.concat(errors)
    end

    def prepare_provider_turn(signal)
      refresh_extension_provider
      maybe_compact(signal)
    end

    def chat_current_turn
      refresh_extension_provider
      @provider.chat(messages: @messages, tools: @toolbox.to_schema, model: @model)
    end

    def stream_current_turn(signal)
      refresh_extension_provider
      @provider.chat_stream(messages: @messages, tools: @toolbox.to_schema, model: @model,
                            signal: signal) do |event|
        emit(:stream, event: event)
        yield event if block_given?
      end
    end

    def default_extension_provider_name(provider)
      return nil if @extension_source.nil?

      provider.name
    rescue StandardError
      nil
    end

    def refresh_extension_provider
      options = Extensions.provider_options(@extension_source, @extension_provider_name)
      signature = extension_provider_signature(options)
      return if signature == @extension_provider_signature

      @extension_provider_signature = signature
      return restore_extension_provider unless options

      @provider = Providers::OpenAI.new(**merge_extension_provider_overrides(options))
    end

    def current_extension_provider_signature
      extension_provider_signature(
        Extensions.provider_options(@extension_source, @extension_provider_name)
      )
    end

    def extension_provider_signature(options)
      options&.inspect
    end

    def merge_extension_provider_overrides(options)
      merged = options.merge(@extension_provider_overrides)
      if options[:headers].is_a?(Hash) && @extension_provider_overrides[:headers].is_a?(Hash)
        merged[:headers] = options[:headers].merge(@extension_provider_overrides[:headers])
      end
      merged
    end

    def restore_extension_provider
      if built_in_extension_provider?
        @provider = Truffle::PROVIDERS.fetch(@extension_provider_name.to_sym)
                                      .new(**@extension_provider_overrides)
      elsif @extension_provider_initial_options.nil?
        @provider = @extension_provider_initial_provider
      else
        raise Error,
              "extension provider #{@extension_provider_name.inspect} is no longer registered"
      end
    end

    def built_in_extension_provider?
      Truffle::PROVIDERS.key?(@extension_provider_name&.to_sym)
    end
  end
end
