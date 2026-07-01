# frozen_string_literal: true

require_relative "model"

module Truffle
  # The model catalog: every model Truffle knows how to address and price, the
  # way pi keeps a generated table per provider. This is the single source of
  # truth for pricing (Pricing reads it) and for any "what can this model do"
  # lookup. Keep it current: the values below are transcribed from provider
  # docs, and a stale entry is a bug. Use script/refresh-models to regenerate a
  # candidate catalog from models.dev/api.json; the runtime catalog never fetches
  # the network at require time.
  #
  # Costs are US dollars per million tokens. cache_write is the 5-minute write
  # rate; the 1-hour write (2x base input) is derived at cost time. OpenAI does
  # not bill a separate cache write, so its cache_write is 0.
  #
  # Lookups accept either a base id (claude-opus-4-8, gpt-4o) or a dated snapshot
  # (claude-sonnet-4-5-20250929, gpt-4o-2024-08-06); the snapshot prices and
  # resolves as its base model.
  module Models
    # Anthropic Messages API. Source: Anthropic model overview + pricing pages
    # (Fable 5, Opus 4.8/4.7/4.6/4.5, Sonnet 4.6/4.5, Haiku 4.5). Only first-party
    # callable models are listed; retired ids are dropped rather than left to rot.
    # The 1M context window is the published figure for Fable 5, Opus 4.6 and up,
    # and Sonnet 4.6; older tiers stay at the standard 200K.
    ANTHROPIC = [
      Model.new(id: "claude-fable-5", name: "Claude Fable 5",
                provider: :anthropic, api: :anthropic_messages, reasoning: true,
                context_window: 1_000_000, max_output: 128_000,
                cost: { input: 10.0, output: 50.0, cache_read: 1.0, cache_write: 12.5 }),
      Model.new(id: "claude-opus-4-8", name: "Claude Opus 4.8",
                provider: :anthropic, api: :anthropic_messages, reasoning: true,
                context_window: 1_000_000, max_output: 128_000,
                cost: { input: 5.0, output: 25.0, cache_read: 0.5, cache_write: 6.25 }),
      Model.new(id: "claude-opus-4-7", name: "Claude Opus 4.7",
                provider: :anthropic, api: :anthropic_messages, reasoning: true,
                context_window: 1_000_000, max_output: 128_000,
                cost: { input: 5.0, output: 25.0, cache_read: 0.5, cache_write: 6.25 }),
      Model.new(id: "claude-opus-4-6", name: "Claude Opus 4.6",
                provider: :anthropic, api: :anthropic_messages, reasoning: true,
                context_window: 1_000_000, max_output: 128_000,
                cost: { input: 5.0, output: 25.0, cache_read: 0.5, cache_write: 6.25 }),
      Model.new(id: "claude-opus-4-5", name: "Claude Opus 4.5",
                provider: :anthropic, api: :anthropic_messages, reasoning: true,
                context_window: 200_000, max_output: 64_000,
                cost: { input: 5.0, output: 25.0, cache_read: 0.5, cache_write: 6.25 }),
      Model.new(id: "claude-opus-4-1", name: "Claude Opus 4.1",
                provider: :anthropic, api: :anthropic_messages, reasoning: true,
                deprecated: true, context_window: 200_000, max_output: 32_000,
                cost: { input: 15.0, output: 75.0, cache_read: 1.5, cache_write: 18.75 }),
      Model.new(id: "claude-sonnet-4-6", name: "Claude Sonnet 4.6",
                provider: :anthropic, api: :anthropic_messages, reasoning: true,
                context_window: 1_000_000, max_output: 64_000,
                cost: { input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75 }),
      Model.new(id: "claude-sonnet-4-5", name: "Claude Sonnet 4.5",
                provider: :anthropic, api: :anthropic_messages, reasoning: true,
                context_window: 200_000, max_output: 64_000,
                cost: { input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75 }),
      Model.new(id: "claude-haiku-4-5", name: "Claude Haiku 4.5",
                provider: :anthropic, api: :anthropic_messages, reasoning: true,
                context_window: 200_000, max_output: 64_000,
                cost: { input: 1.0, output: 5.0, cache_read: 0.1, cache_write: 1.25 })
    ].freeze

    # OpenAI Chat Completions API. Source: OpenAI model and pricing pages
    # (gpt-5.5, the gpt-5.4 family, the gpt-5 family, gpt-4.1 family, gpt-4o
    # family). cache_read is the cached-input rate; OpenAI bills no cache write.
    OPENAI = [
      Model.new(id: "gpt-5.5", name: "GPT-5.5",
                provider: :openai, api: :openai_completions, reasoning: true,
                context_window: 1_000_000, max_output: 128_000,
                cost: { input: 5.0, output: 30.0, cache_read: 0.5, cache_write: 0.0 }),
      Model.new(id: "gpt-5.4", name: "GPT-5.4",
                provider: :openai, api: :openai_completions, reasoning: true,
                context_window: 1_000_000, max_output: 128_000,
                cost: { input: 2.5, output: 15.0, cache_read: 0.25, cache_write: 0.0 }),
      Model.new(id: "gpt-5.4-mini", name: "GPT-5.4 mini",
                provider: :openai, api: :openai_completions, reasoning: true,
                context_window: 400_000, max_output: 128_000,
                cost: { input: 0.75, output: 4.5, cache_read: 0.075, cache_write: 0.0 }),
      Model.new(id: "gpt-5.4-nano", name: "GPT-5.4 nano",
                provider: :openai, api: :openai_completions, reasoning: true,
                context_window: 400_000, max_output: 128_000,
                cost: { input: 0.2, output: 1.25, cache_read: 0.02, cache_write: 0.0 }),
      Model.new(id: "gpt-5", name: "GPT-5",
                provider: :openai, api: :openai_completions, reasoning: true,
                context_window: 400_000, max_output: 128_000,
                cost: { input: 1.25, output: 10.0, cache_read: 0.125, cache_write: 0.0 }),
      Model.new(id: "gpt-5-mini", name: "GPT-5 mini",
                provider: :openai, api: :openai_completions, reasoning: true,
                context_window: 400_000, max_output: 128_000,
                cost: { input: 0.25, output: 2.0, cache_read: 0.025, cache_write: 0.0 }),
      Model.new(id: "gpt-5-nano", name: "GPT-5 nano",
                provider: :openai, api: :openai_completions, reasoning: true,
                context_window: 400_000, max_output: 128_000,
                cost: { input: 0.05, output: 0.4, cache_read: 0.005, cache_write: 0.0 }),
      Model.new(id: "gpt-4.1", name: "GPT-4.1",
                provider: :openai, api: :openai_completions,
                context_window: 1_000_000, max_output: 32_768,
                cost: { input: 2.0, output: 8.0, cache_read: 0.5, cache_write: 0.0 }),
      Model.new(id: "gpt-4.1-mini", name: "GPT-4.1 mini",
                provider: :openai, api: :openai_completions,
                context_window: 1_000_000, max_output: 32_768,
                cost: { input: 0.4, output: 1.6, cache_read: 0.1, cache_write: 0.0 }),
      Model.new(id: "gpt-4.1-nano", name: "GPT-4.1 nano",
                provider: :openai, api: :openai_completions,
                context_window: 1_000_000, max_output: 32_768,
                cost: { input: 0.1, output: 0.4, cache_read: 0.025, cache_write: 0.0 }),
      Model.new(id: "gpt-4o", name: "GPT-4o",
                provider: :openai, api: :openai_completions,
                context_window: 128_000, max_output: 16_384,
                cost: { input: 2.5, output: 10.0, cache_read: 1.25, cache_write: 0.0 }),
      Model.new(id: "gpt-4o-mini", name: "GPT-4o mini",
                provider: :openai, api: :openai_completions,
                context_window: 128_000, max_output: 16_384,
                cost: { input: 0.15, output: 0.6, cache_read: 0.075, cache_write: 0.0 })
    ].freeze

    # Google Gemini Generative Language API. Source: Google's Gemini API model
    # and pricing pages (Gemini 3.5 Flash, 3.1 Pro Preview, 3.1 Flash-Lite, and
    # the 2.5 Pro/Flash/Flash-Lite family). Only first-party callable text models
    # are listed; the image, audio, TTS, video, embedding, and specialized
    # endpoints are out of scope, and the retired 2.0 family (shut down
    # 2026-06-01) and Gemma open models are dropped. Costs are the text/image/
    # video input rate and the standard (<=200K-token) tier where a model charges
    # a long-context premium above it. Gemini's generateContent endpoint bills
    # context-cache reads but exposes no separate cache-write counter, so
    # cache_write is 0. The 1M context window and 64K max output are the published
    # figures for the 2.5 and 3.x text tiers.
    GOOGLE = [
      Model.new(id: "gemini-3.5-flash", name: "Gemini 3.5 Flash",
                provider: :google, api: :google_generative_ai, reasoning: true,
                context_window: 1_048_576, max_output: 65_536,
                cost: { input: 1.5, output: 9.0, cache_read: 0.15, cache_write: 0.0 }),
      Model.new(id: "gemini-3.1-pro-preview", name: "Gemini 3.1 Pro Preview",
                provider: :google, api: :google_generative_ai, reasoning: true,
                context_window: 1_048_576, max_output: 65_536,
                cost: { input: 2.0, output: 12.0, cache_read: 0.2, cache_write: 0.0 }),
      Model.new(id: "gemini-3.1-flash-lite", name: "Gemini 3.1 Flash-Lite",
                provider: :google, api: :google_generative_ai, reasoning: true,
                context_window: 1_048_576, max_output: 65_536,
                cost: { input: 0.25, output: 1.5, cache_read: 0.025, cache_write: 0.0 }),
      Model.new(id: "gemini-2.5-pro", name: "Gemini 2.5 Pro",
                provider: :google, api: :google_generative_ai, reasoning: true,
                context_window: 1_048_576, max_output: 65_536,
                cost: { input: 1.25, output: 10.0, cache_read: 0.125, cache_write: 0.0 }),
      Model.new(id: "gemini-2.5-flash", name: "Gemini 2.5 Flash",
                provider: :google, api: :google_generative_ai, reasoning: true,
                context_window: 1_048_576, max_output: 65_536,
                cost: { input: 0.3, output: 2.5, cache_read: 0.03, cache_write: 0.0 }),
      Model.new(id: "gemini-2.5-flash-lite", name: "Gemini 2.5 Flash-Lite",
                provider: :google, api: :google_generative_ai, reasoning: true,
                context_window: 1_048_576, max_output: 65_536,
                cost: { input: 0.1, output: 0.4, cache_read: 0.01, cache_write: 0.0 })
    ].freeze

    ALL = (ANTHROPIC + OPENAI + GOOGLE).freeze

    BY_ID = ALL.to_h { |m| [m.id, m] }.freeze

    module_function

    # Every known model.
    def all = ALL

    # Models served by one provider symbol (:openai, :anthropic), [] if unknown.
    def for_provider(provider)
      ALL.select { |m| m.provider == provider.to_sym }
    end

    # Look up a model by id. Matches an exact id first, then retries with a
    # trailing date snapshot stripped, so a dated id resolves to its base model.
    # Returns nil for an unknown or nil id.
    def find(id)
      return nil if id.nil?

      BY_ID[id] || BY_ID[base_id(id)]
    end
    class << self
      alias [] find
    end

    # Resolve a model reference to its catalog Model, the way pi's
    # findExactModelReferenceMatch does, so a caller can name a model without
    # also naming its provider. Accepts a bare id ("claude-opus-4-8"), a
    # canonical "provider/id" reference ("anthropic/claude-opus-4-8"), or a dated
    # snapshot of either. Matching trims surrounding space and is
    # case-insensitive. A bare id served by more than one provider is ambiguous
    # and resolves to nil rather than guessing. Returns nil for an unknown or nil
    # reference.
    #
    # `models:` is the list to match against, defaulting to the full catalog;
    # passing a list keeps the matcher a pure function (and lets a caller scope
    # to a subset), the way pi threads availableModels through.
    def resolve(reference, models: ALL)
      trimmed = reference.to_s.strip
      return nil if trimmed.empty?

      # Tried in order: a canonical "provider/id", then a slash-split provider
      # plus id, then a bare id. Each returns the single match, or nil when the
      # step is ambiguous (more than one match) so we never guess.
      one_of(models) { |m| "#{m.provider}/#{m.id}".casecmp?(trimmed) } ||
        resolve_with_provider(trimmed, models) ||
        one_of(models) { |m| id_match?(m, trimmed) }
    end

    # The provider symbol that serves a model reference, or nil when the
    # reference does not resolve. The convenience behind inferring a provider in
    # Truffle.agent from `model:` alone.
    def provider_for(reference)
      resolve(reference)&.provider
    end

    # The single model the block selects, or nil when zero or more than one
    # match. The "more than one" case is what makes an ambiguous reference
    # resolve to nil instead of an arbitrary pick.
    def one_of(models, &)
      matches = models.select(&)
      matches.length == 1 ? matches.first : nil
    end

    # The slash step of resolve: split "provider/id", then match within that
    # provider. nil when there is no usable slash so resolve falls through to a
    # bare-id match.
    def resolve_with_provider(reference, models)
      slash = reference.index("/")
      return nil unless slash

      provider = reference[0...slash].strip
      model_id = reference[(slash + 1)..].strip
      return nil if provider.empty? || model_id.empty?

      one_of(models) { |m| m.provider.to_s.casecmp?(provider) && id_match?(m, model_id) }
    end

    # Strip a trailing date snapshot so a dated id resolves as its base. OpenAI
    # snapshots are dashed (gpt-4o-2024-08-06); Anthropic snapshots are compact
    # (claude-sonnet-4-5-20250929). Handle both.
    def base_id(id)
      id.sub(/-\d{4}-\d{2}-\d{2}\z/, "").sub(/-\d{8}\z/, "")
    end

    # A model id matches a reference exactly, or matches once a dated snapshot
    # suffix is stripped from the reference, so "gpt-4o-2024-08-06" resolves like
    # "gpt-4o". Case-insensitive to mirror pi's matcher.
    def id_match?(model, reference)
      ref = reference.downcase
      id = model.id.downcase
      id == ref || id == base_id(ref)
    end
  end
end
