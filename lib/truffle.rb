# frozen_string_literal: true

require_relative "truffle/version"
require_relative "truffle/content"
require_relative "truffle/mime"
require_relative "truffle/unicode_sanitizer"
require_relative "truffle/short_hash"
require_relative "truffle/stop_reason"
require_relative "truffle/abort_signal"
require_relative "truffle/event_bus"
require_relative "truffle/model"
require_relative "truffle/models"
require_relative "truffle/pricing"
require_relative "truffle/usage"
require_relative "truffle/message"
require_relative "truffle/uuid"
require_relative "truffle/frontmatter"
require_relative "truffle/config"
require_relative "truffle/migrations"
require_relative "truffle/settings"
require_relative "truffle/prompt_templates"
require_relative "truffle/slash_commands"
require_relative "truffle/session"
require_relative "truffle/session_fork"
require_relative "truffle/session_cwd"
require_relative "truffle/json_repair"
require_relative "truffle/partial_json"
require_relative "truffle/response"
require_relative "truffle/overflow"
require_relative "truffle/retry"
require_relative "truffle/stream_event"
require_relative "truffle/tool"
require_relative "truffle/toolbox"
require_relative "truffle/schema"
require_relative "truffle/schema_coercion"
require_relative "truffle/token_budget"
require_relative "truffle/message_transform"
require_relative "truffle/providers/base"
require_relative "truffle/providers/sse"
require_relative "truffle/providers/openai"
require_relative "truffle/providers/openai_stream"
require_relative "truffle/providers/anthropic"
require_relative "truffle/providers/anthropic_stream"
require_relative "truffle/providers/google"
require_relative "truffle/providers/google_stream"
require_relative "truffle/extensions"
require_relative "truffle/extensions/providers"
require_relative "truffle/provider_registry"
require_relative "truffle/agent"
require_relative "truffle/agent/extensions"
require_relative "truffle/agent/tool_execution"
require_relative "truffle/agent/slash_commands"
require_relative "truffle/agent/run_loop"
require_relative "truffle/compaction"
require_relative "truffle/ignore"
require_relative "truffle/skills"
require_relative "truffle/context_files"
require_relative "truffle/system_prompt"
require_relative "truffle/tools"
require_relative "truffle/cli"
require_relative "truffle/cli/help"
require_relative "truffle/cli/init"
require_relative "truffle/cli/models"
require_relative "truffle/cli/runner"
require_relative "truffle/cli/print"
require_relative "truffle/cli/repl"

# Truffle is a complete agent harness for Ruby, built from scratch.
#
# It is a faithful port of earendil-works/pi to idiomatic Ruby: the agent-core
# runtime (tool calling, state, and an event-streaming protocol), with a
# provider-agnostic LLM seam written from the ground up and no runtime gem
# dependencies.
#
# Quick start:
#
#   require "truffle"
#
#   add = Truffle::Tool.define("add", "Add two integers") do
#     param :a, :integer, required: true
#     param :b, :integer, required: true
#     run { |a:, b:| a + b }
#   end
#
#   agent = Truffle.agent(
#     provider: :openai,
#     system_prompt: "You are a precise calculator. Use tools for arithmetic.",
#     tools: [add]
#   )
#   puts agent.run("What is 21 plus 21?")
module Truffle
  # Generic Truffle error type; provider HTTP errors are Truffle::Providers::Error.
  class Error < StandardError; end

  PROVIDERS = {
    openai: Providers::OpenAI,
    anthropic: Providers::Anthropic,
    google: Providers::Google
  }.freeze

  module_function

  # Build a provider by symbol (:openai), an extension-registered provider, an
  # in-process registered provider, or pass a ready-made instance through.
  def provider(name, extensions: nil, **options)
    return name if name.is_a?(Providers::Base)

    extension_options = Extensions.provider_options(extensions, name)
    return openai_compatible_provider(extension_options, options) if extension_options

    registered_options = ProviderRegistry.provider_options(name)
    return openai_compatible_provider(registered_options, options) if registered_options

    klass = PROVIDERS[name.to_sym]
    if klass.nil?
      known = (
        PROVIDERS.keys.map(&:to_s) +
        Extensions.provider_names(extensions) +
        ProviderRegistry.provider_names
      ).uniq
      raise Error, "unknown provider #{name.inspect}, known: #{known.inspect}"
    end

    klass.new(**options)
  end

  # Register an OpenAI Chat Completions-compatible provider in-process, without a
  # `.truffle/extensions` file. The config keys match `truffle.register_provider`.
  def register_provider(name, config)
    ProviderRegistry.register(name, config)
  end

  def unregister_provider(name)
    ProviderRegistry.unregister(name)
  end

  def registered_provider_names
    ProviderRegistry.provider_names
  end

  # Convenience constructor: Truffle.agent(provider: :openai, tools: [...], ...).
  # `provider:` may be a symbol, an options-less default, or a provider instance.
  #
  # `provider:` is optional when `model:` names a catalog model: the provider is
  # then inferred from the model (Truffle.agent(model: "claude-opus-4-8")), and a
  # canonical "provider/id" reference is reduced to the bare wire id the provider
  # expects. An explicit `provider:` is left untouched, so an unlisted or custom
  # model id still works when the provider is named.
  def agent(provider: nil, system_prompt: nil, tools: [], model: nil,
            max_turns: nil, tool_execution: :parallel,
            prompt_templates: [], slash_commands: nil, extensions: nil,
            session: nil,
            compaction_settings: nil, retry_settings: nil,
            settings: :project, cwd: Dir.pwd,
            **provider_options)
    runtime_settings = resolve_settings(settings, cwd: cwd)
    provider ||= runtime_settings.default_provider
    model ||= runtime_settings.default_model
    max_turns ||= Agent::DEFAULT_MAX_TURNS
    compaction_settings ||= runtime_settings.compaction_settings
    retry_settings ||= runtime_settings.retry_settings

    provider, model = resolve_agent_model(provider, model, extensions)

    provider_name = provider.is_a?(Providers::Base) ? provider.name : provider.to_s
    prov = provider(provider, extensions: extensions, **provider_options)
    Agent.new(
      provider: prov,
      system_prompt: system_prompt,
      tools: tools,
      model: model,
      max_turns: max_turns,
      session: session,
      compaction_settings: compaction_settings,
      retry_settings: retry_settings,
      tool_execution: tool_execution,
      prompt_templates: prompt_templates,
      slash_commands: slash_commands,
      extensions: extensions,
      extension_provider_name: provider_name,
      extension_provider_overrides: provider_options
    )
  end

  def resolve_agent_model(provider, model, extensions)
    return [provider, model] unless provider.nil?
    raise Error, "pass provider:, or a model: that names one" if model.nil?

    resolved = Models.resolve(model) || Extensions.model_reference(extensions, model) ||
               ProviderRegistry.model_reference(model)
    unless resolved
      raise Error, "cannot infer a provider from model #{model.inspect}; pass provider:"
    end

    [resolved.provider, resolved.respond_to?(:model_id) ? resolved.model_id : resolved.id]
  end
  private_class_method :resolve_agent_model

  def openai_compatible_provider(registered_options, caller_options)
    combined_options = registered_options.merge(caller_options)
    if registered_options[:headers].is_a?(Hash) && caller_options[:headers].is_a?(Hash)
      combined_options[:headers] = registered_options[:headers].merge(caller_options[:headers])
    end
    Providers::OpenAI.new(**combined_options)
  end
  private_class_method :openai_compatible_provider

  def resolve_settings(settings, cwd:)
    case settings
    when nil, false
      Settings.empty
    when :project, true
      Settings.try_load_project(cwd: cwd)
    when Settings
      settings
    else
      raise Error, "settings must be a Truffle::Settings, :project, true, false, or nil"
    end
  end
  private_class_method :resolve_settings

  # Define a tool: Truffle.tool("name", "desc") { param ...; run { ... } }.
  def tool(name, description, execution_mode: :parallel, &)
    Tool.define(name, description, execution_mode: execution_mode, &)
  end

  # The model catalog. `Truffle.models` lists every known model;
  # `Truffle.model("claude-opus-4-8")` looks one up (nil if unknown), accepting a
  # dated snapshot id as its base model.
  def models = Models.all

  def model(id) = Models.find(id)

  # Resolve a model reference (bare id or "provider/id", dated snapshots welcome)
  # to its catalog Model, or nil when it does not resolve unambiguously.
  def resolve_model(reference) = Models.resolve(reference)
end
