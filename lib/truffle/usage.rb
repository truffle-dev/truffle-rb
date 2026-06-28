# frozen_string_literal: true

module Truffle
  # Token accounting for one assistant turn, plus the dollar cost of those
  # tokens. A faithful port of pi's Usage (packages/ai/src/types.ts) and its
  # parseChunkUsage / calculateCost helpers (openai-completions.ts, models.ts).
  #
  # Token fields:
  # - input:       prompt tokens billed at the full input rate (cache misses)
  # - output:      completion tokens, already inclusive of any reasoning tokens
  # - cache_read:  prompt tokens served from the provider's cache (discounted)
  # - cache_write: prompt tokens written into the cache this turn
  # - reasoning:   thinking tokens, a subset of output, when the provider reports them
  #
  # input is the residual after cache reads and writes, matching pi: a cached
  # prompt token is billed once as a read, not also as a fresh input token.
  class Usage
    # Per-token-class dollar cost for a turn. Mirrors pi's Usage["cost"].
    Cost = Struct.new(:input, :output, :cache_read, :cache_write, :total, keyword_init: true) do
      def to_h
        { input: input, output: output, cache_read: cache_read,
          cache_write: cache_write, total: total }
      end
    end

    attr_reader :input, :output, :cache_read, :cache_write, :cache_write_1h,
                :reasoning, :total_tokens, :cost

    def initialize(input: 0, output: 0, cache_read: 0, cache_write: 0,
                   cache_write_1h: 0, reasoning: 0, cost: nil)
      @input = input
      @output = output
      @cache_read = cache_read
      @cache_write = cache_write
      @cache_write_1h = cache_write_1h
      @reasoning = reasoning
      @total_tokens = input + output + cache_read + cache_write
      @cost = cost || Cost.new(input: 0.0, output: 0.0, cache_read: 0.0,
                               cache_write: 0.0, total: 0.0)
    end

    # An empty usage: the identity for #+.
    def self.zero
      new
    end

    # Build a Usage from a provider's raw usage hash (OpenAI Chat Completions
    # shape, string keys from JSON). `pricing` is a per-million-token rate hash
    # (Pricing.cost_for); when given, the dollar cost is filled in. Faithful to
    # pi's parseChunkUsage: cache reads come from prompt_tokens_details.cached_tokens
    # (falling back to the prompt_cache_hit_tokens some providers use), and input
    # is the residual so a cached token is not also counted as fresh input.
    def self.parse(raw, pricing: nil)
      raw ||= {}
      prompt = (raw["prompt_tokens"] || 0).to_i
      details = raw["prompt_tokens_details"] || {}
      completion_details = raw["completion_tokens_details"] || {}

      cache_read = (details["cached_tokens"] || raw["prompt_cache_hit_tokens"] || 0).to_i
      cache_write = (details["cache_write_tokens"] || 0).to_i
      input = [0, prompt - cache_read - cache_write].max
      output = (raw["completion_tokens"] || 0).to_i
      reasoning = (completion_details["reasoning_tokens"] || 0).to_i

      usage = new(input: input, output: output, cache_read: cache_read,
                  cache_write: cache_write, reasoning: reasoning)
      pricing ? usage.with_cost(pricing) : usage
    end

    # Build a Usage from Anthropic's Messages API usage hash. Unlike OpenAI,
    # Anthropic reports input_tokens directly (already net of cache reads and
    # writes), so input is taken as-is rather than computed as a residual.
    # cache_creation_input_tokens is the total cache write; its 1h-retention
    # slice (cache_creation.ephemeral_1h_input_tokens) is split out so
    # with_cost can bill it at 2x base input, the way pi's calculateCost does.
    # reasoning comes from output_tokens_details.thinking_tokens, a subset of
    # output. Faithful to pi's message_start/message_delta usage capture.
    def self.from_anthropic(raw, pricing: nil)
      raw ||= {}
      cache_creation = raw["cache_creation"] || {}
      output_details = raw["output_tokens_details"] || {}

      usage = new(
        input: (raw["input_tokens"] || 0).to_i,
        output: (raw["output_tokens"] || 0).to_i,
        cache_read: (raw["cache_read_input_tokens"] || 0).to_i,
        cache_write: (raw["cache_creation_input_tokens"] || 0).to_i,
        cache_write_1h: (cache_creation["ephemeral_1h_input_tokens"] || 0).to_i,
        reasoning: (output_details["thinking_tokens"] || 0).to_i
      )
      pricing ? usage.with_cost(pricing) : usage
    end

    # Return a copy of this usage with cost computed from a per-million rate hash.
    # Port of pi's calculateCost: Anthropic bills 1h cache writes at 2x base input,
    # so the 1h slice is split out; OpenAI never sets it, leaving short = cache_write.
    def with_cost(pricing)
      rates = normalize_pricing(pricing)
      long_write = cache_write_1h
      short_write = cache_write - long_write
      computed = Cost.new(
        input: per_million(rates[:input], input),
        output: per_million(rates[:output], output),
        cache_read: per_million(rates[:cache_read], cache_read),
        cache_write: ((rates[:cache_write] * short_write) +
                      (rates[:input] * 2 * long_write)) / 1_000_000.0,
        total: 0.0
      )
      computed.total = computed.input + computed.output + computed.cache_read + computed.cache_write
      self.class.new(input: input, output: output, cache_read: cache_read,
                     cache_write: cache_write, cache_write_1h: cache_write_1h,
                     reasoning: reasoning, cost: computed)
    end

    # Sum two usages: tokens and dollar costs add. Used to aggregate across the
    # turns of a run. reasoning sums too, since it is a subset of each turn's output.
    def +(other)
      merged_cost = Cost.new(
        input: cost.input + other.cost.input,
        output: cost.output + other.cost.output,
        cache_read: cost.cache_read + other.cost.cache_read,
        cache_write: cost.cache_write + other.cost.cache_write,
        total: cost.total + other.cost.total
      )
      self.class.new(
        input: input + other.input,
        output: output + other.output,
        cache_read: cache_read + other.cache_read,
        cache_write: cache_write + other.cache_write,
        cache_write_1h: cache_write_1h + other.cache_write_1h,
        reasoning: reasoning + other.reasoning,
        cost: merged_cost
      )
    end

    def to_h
      { input: input, output: output, cache_read: cache_read,
        cache_write: cache_write, reasoning: reasoning,
        total_tokens: total_tokens, cost: cost.to_h }
    end

    def ==(other)
      other.is_a?(Usage) && to_h == other.to_h
    end
    alias eql? ==

    def hash
      to_h.hash
    end

    private

    def per_million(rate, tokens)
      (rate / 1_000_000.0) * tokens
    end

    def normalize_pricing(pricing)
      {
        input: pricing[:input] || 0,
        output: pricing[:output] || 0,
        cache_read: pricing[:cache_read] || 0,
        cache_write: pricing[:cache_write] || 0
      }
    end
  end
end
