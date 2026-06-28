# frozen_string_literal: true

require_relative "truffle/version"
require_relative "truffle/content"
require_relative "truffle/stop_reason"
require_relative "truffle/message"
require_relative "truffle/response"
require_relative "truffle/stream_event"
require_relative "truffle/tool"
require_relative "truffle/toolbox"
require_relative "truffle/providers/base"
require_relative "truffle/providers/openai"
require_relative "truffle/providers/openai_stream"
require_relative "truffle/agent"

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

  # Convenience constructor: Truffle.agent(provider: :openai, tools: [...], ...).
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

  # Define a tool: Truffle.tool("name", "desc") { param ...; run { ... } }.
  def tool(name, description, &block)
    Tool.define(name, description, &block)
  end
end
