# frozen_string_literal: true

require_relative "models"

module Truffle
  # Per-model token pricing, in US dollars per million tokens. This is a thin
  # facade over the model catalog (Models): the rates live on each Model, and
  # Pricing exists so the provider and usage code can ask for a rate hash by id
  # without reaching into the catalog. An unknown model returns nil so token
  # counting still works without a guessed price.
  module Pricing
    module_function

    # The per-million-token rate hash for a model id, or nil when the catalog has
    # no entry. Resolves a dated snapshot to its base model (gpt-4o-2024-08-06
    # prices as gpt-4o, claude-sonnet-4-5-20250929 as claude-sonnet-4-5).
    def cost_for(model_id)
      Models.find(model_id)&.cost
    end

    # Strip a trailing date snapshot so a dated model id prices as its base.
    # Kept for callers that want the base id directly; the lookup in cost_for
    # already does this.
    def base_model(model_id)
      Models.base_id(model_id)
    end
  end
end
