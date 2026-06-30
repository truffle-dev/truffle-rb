# frozen_string_literal: true

require_relative "truffle/version"
require_relative "truffle/content"
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
require_relative "truffle/prompt_templates"
require_relative "truffle/session"
require_relative "truffle/response"
require_relative "truffle/overflow"
require_relative "truffle/retry"
require_relative "truffle/stream_event"
require_relative "truffle/tool"
require_relative "truffle/toolbox"
require_relative "truffle/providers/base"
require_relative "truffle/providers/sse"
require_relative "truffle/providers/openai"
require_relative "truffle/providers/openai_stream"
require_relative "truffle/providers/anthropic"
require_relative "truffle/providers/anthropic_stream"
require_relative "truffle/providers/google"
require_relative "truffle/providers/google_stream"
require_relative "truffle/agent"
require_relative "truffle/agent/tool_execution"
require_relative "truffle/compaction"
require_relative "truffle/ignore"
require_relative "truffle/skills"
require_relative "truffle/extensions"
require_relative "truffle/tools"

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

  # Build a provider by symbol (:openai) or pass a ready-made instance through.
  def provider(name, **options)
    return name if name.is_a?(Providers::Base)

    klass = PROVIDERS[name.to_sym]
    raise Error, "unknown provider #{name.inspect}, known: #{PROVIDERS.keys.inspect}" if klass.nil?

    klass.new(**options)
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
            max_turns: Agent::DEFAULT_MAX_TURNS, tool_execution: :parallel,
            **provider_options)
    if provider.nil?
      raise Error, "pass provider:, or a model: that names one" if model.nil?

      resolved = Models.resolve(model)
      if resolved.nil?
        raise Error, "cannot infer a provider from model #{model.inspect}; pass provider:"
      end

      provider = resolved.provider
      model = resolved.id
    end

    prov = provider(provider, **provider_options)
    Agent.new(
      provider: prov,
      system_prompt: system_prompt,
      tools: tools,
      model: model,
      max_turns: max_turns,
      tool_execution: tool_execution
    )
  end

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
