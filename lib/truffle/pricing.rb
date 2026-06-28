# frozen_string_literal: true

module Truffle
  # Per-model token pricing, in US dollars per million tokens. A small port of
  # the cost entries pi keeps on each model (packages/ai/src/providers/*.models.ts).
  # Truffle ships the OpenAI table it can bill against today; an unknown model
  # prices at zero so token counting still works without guessing at a rate.
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

    module_function

    # The rate hash for a model id, or nil when we have no pricing for it. Matched
    # exactly first, then with a trailing date snapshot stripped (gpt-4o-2024-08-06
    # prices as gpt-4o), the way OpenAI snapshots share their base model's rate.
    def cost_for(model_id)
      return nil if model_id.nil?

      OPENAI[model_id] || OPENAI[base_model(model_id)]
    end

    def base_model(model_id)
      model_id.sub(/-\d{4}-\d{2}-\d{2}\z/, "")
    end
  end
end
