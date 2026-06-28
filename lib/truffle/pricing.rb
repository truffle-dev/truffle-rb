# frozen_string_literal: true

module Truffle
  # Per-model token pricing, in US dollars per million tokens. A small port of
  # the cost entries pi keeps on each model (packages/ai/src/providers/*.models.ts).
  # Truffle ships the OpenAI and Anthropic tables it can bill against today; an
  # unknown model prices at zero so token counting still works without guessing.
  module Pricing
    # cache_write is 0 for OpenAI: the API discounts cache reads but does not
    # charge a separate write, matching pi's entries. Rates verified against pi.
    OPENAI = {
      "gpt-4o" =>        { input: 2.5,  output: 10.0, cache_read: 1.25,  cache_write: 0.0 },
      "gpt-4o-mini" =>   { input: 0.15, output: 0.6,  cache_read: 0.075, cache_write: 0.0 },
      "gpt-4.1" =>       { input: 2.0,  output: 8.0,  cache_read: 0.5,   cache_write: 0.0 },
      "gpt-4.1-mini" =>  { input: 0.4,  output: 1.6,  cache_read: 0.1,   cache_write: 0.0 },
      "gpt-4.1-nano" =>  { input: 0.1,  output: 0.4,  cache_read: 0.025, cache_write: 0.0 },
      "gpt-5" =>         { input: 1.25, output: 10.0, cache_read: 0.125, cache_write: 0.0 },
      "gpt-5-mini" =>    { input: 0.25, output: 2.0,  cache_read: 0.025, cache_write: 0.0 },
      "gpt-5-nano" =>    { input: 0.05, output: 0.4,  cache_read: 0.005, cache_write: 0.0 }
    }.freeze

    # Anthropic charges a real cache write: the 5-minute write is 1.25x base
    # input and the read is 0.1x, the standard Messages API rates. The 1h-write
    # premium (2x input) is applied at cost time from cache_write_1h, so the
    # cache_write rate here is the 5m rate. Keyed by base model id (a trailing
    # -YYYY-MM-DD snapshot is stripped before lookup).
    ANTHROPIC = {
      "claude-opus-4-6" =>   { input: 5.0,  output: 25.0, cache_read: 0.5,  cache_write: 6.25 },
      "claude-opus-4-5" =>   { input: 5.0,  output: 25.0, cache_read: 0.5,  cache_write: 6.25 },
      "claude-opus-4-1" =>   { input: 15.0, output: 75.0, cache_read: 1.5,  cache_write: 18.75 },
      "claude-opus-4" =>     { input: 15.0, output: 75.0, cache_read: 1.5,  cache_write: 18.75 },
      "claude-sonnet-4-5" => { input: 3.0,  output: 15.0, cache_read: 0.3,  cache_write: 3.75 },
      "claude-sonnet-4" =>   { input: 3.0,  output: 15.0, cache_read: 0.3,  cache_write: 3.75 },
      "claude-haiku-4-5" =>  { input: 1.0,  output: 5.0,  cache_read: 0.1,  cache_write: 1.25 },
      "claude-3-7-sonnet" => { input: 3.0,  output: 15.0, cache_read: 0.3,  cache_write: 3.75 },
      "claude-3-5-sonnet" => { input: 3.0,  output: 15.0, cache_read: 0.3,  cache_write: 3.75 },
      "claude-3-5-haiku" =>  { input: 0.8,  output: 4.0,  cache_read: 0.08, cache_write: 1.0 },
      "claude-3-opus" =>     { input: 15.0, output: 75.0, cache_read: 1.5,  cache_write: 18.75 },
      "claude-3-haiku" =>    { input: 0.25, output: 1.25, cache_read: 0.03, cache_write: 0.3 }
    }.freeze

    # One merged table for lookup. OpenAI and Anthropic ids never collide, so the
    # merge is unambiguous and is frozen once at load.
    RATES = OPENAI.merge(ANTHROPIC).freeze

    module_function

    # The rate hash for a model id, or nil when we have no pricing for it. Matched
    # exactly first, then with a trailing date snapshot stripped (gpt-4o-2024-08-06
    # prices as gpt-4o, claude-sonnet-4-5-20250929 as claude-sonnet-4-5), the way
    # provider snapshots share their base model's rate.
    def cost_for(model_id)
      return nil if model_id.nil?

      RATES[model_id] || RATES[base_model(model_id)]
    end

    # Strip a trailing date snapshot so a dated model id prices as its base.
    # OpenAI snapshots are dashed (gpt-4o-2024-08-06); Anthropic snapshots are
    # compact (claude-sonnet-4-5-20250929). Handle both.
    def base_model(model_id)
      model_id.sub(/-\d{4}-\d{2}-\d{2}\z/, "").sub(/-\d{8}\z/, "")
    end
  end
end
