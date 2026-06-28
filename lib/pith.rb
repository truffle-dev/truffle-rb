# frozen_string_literal: true

require_relative "pith/version"
require_relative "pith/message"
require_relative "pith/response"
require_relative "pith/tool"
require_relative "pith/toolbox"
require_relative "pith/providers/base"
require_relative "pith/providers/openai"
require_relative "pith/agent"

# Pith is a small, provider-agnostic agent harness for Ruby.
#
# It ports the moat of earendil-works/pi (the agent-core runtime: tool calling,
# state, and an event model) to idiomatic Ruby. The provider seam is inspired by
# crmne/ruby_llm: one interface, every model behind it.
#
# Quick start:
#
#   require "pith"
#
#   add = Pith::Tool.define("add", "Add two integers") do
#     param :a, :integer, required: true
#     param :b, :integer, required: true
#     run { |a:, b:| a + b }
#   end
#
#   agent = Pith.agent(
#     provider: :openai,
#     system_prompt: "You are a precise calculator. Use tools for arithmetic.",
#     tools: [add]
#   )
#   puts agent.run("What is 21 plus 21?")
module Pith
  # Generic Pith error type; provider HTTP errors are Pith::Providers::Error.
  class Error < StandardError; end

  PROVIDERS = {
    openai: Providers::OpenAI
  }.freeze

  module_function

  # Build a provider by symbol (:openai) or pass a ready-made instance through.
  def provider(name, **options)
    return name if name.is_a?(Providers::Base)

    klass = PROVIDERS[name.to_sym]
    raise Error, "unknown provider #{name.inspect}, known: #{PROVIDERS.keys.inspect}" if klass.nil?

    klass.new(**options)
  end

  # Convenience constructor: Pith.agent(provider: :openai, tools: [...], ...).
  # `provider:` may be a symbol, an options-less default, or a provider instance.
  def agent(provider:, system_prompt: nil, tools: [], model: nil,
            max_turns: Agent::DEFAULT_MAX_TURNS, **provider_options)
    prov = provider(provider, **provider_options)
    Agent.new(
      provider: prov,
      system_prompt: system_prompt,
      tools: tools,
      model: model,
      max_turns: max_turns
    )
  end

  # Define a tool: Pith.tool("name", "desc") { param ...; run { ... } }.
  def tool(name, description, &block)
    Tool.define(name, description, &block)
  end
end
