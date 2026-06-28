# frozen_string_literal: true

module Truffle
  # One model in the catalog: its id, who serves it, what it can do, and what it
  # costs. A faithful port of the fields pi keeps per model in its generated
  # `*.models.ts` tables (id, name, provider, api, reasoning, input modalities,
  # cost, contextWindow, maxTokens), written as an immutable Ruby value object.
  #
  # `cost` is a per-million-token rate hash in US dollars with the keys
  # `:input`, `:output`, `:cache_read`, and `:cache_write`. `cache_write` is the
  # 5-minute cache-write rate; the 1-hour write (2x base input) is applied at
  # cost time in Usage#with_cost, so providers never store it twice.
  class Model
    attr_reader :id, :name, :provider, :api, :context_window, :max_output,
                :input, :cost

    # input defaults to text+image: every model in the shipped catalog accepts
    # both. reasoning marks models with extended thinking. deprecated flags a
    # model that still answers but is on a retirement path.
    def initialize(id:, name:, provider:, api:, context_window:, max_output:,
                   cost:, input: %i[text image], reasoning: false,
                   deprecated: false)
      @id = id
      @name = name
      @provider = provider
      @api = api
      @context_window = context_window
      @max_output = max_output
      @input = input.freeze
      @reasoning = reasoning
      @deprecated = deprecated
      @cost = { input: cost.fetch(:input), output: cost.fetch(:output),
                cache_read: cost.fetch(:cache_read),
                cache_write: cost.fetch(:cache_write) }.freeze
      freeze
    end

    def reasoning? = @reasoning
    def deprecated? = @deprecated
    def vision? = @input.include?(:image)

    def to_h
      { id: id, name: name, provider: provider, api: api,
        context_window: context_window, max_output: max_output,
        input: input, reasoning: reasoning?, deprecated: deprecated?,
        cost: cost }
    end

    def ==(other)
      other.is_a?(Model) && to_h == other.to_h
    end
    alias eql? ==

    def hash
      to_h.hash
    end
  end
end
