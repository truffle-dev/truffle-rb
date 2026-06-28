# frozen_string_literal: true

module Pith
  # An ordered collection of tools the agent can reach for, keyed by name.
  class Toolbox
    include Enumerable

    def initialize(tools = [])
      @tools = {}
      Array(tools).each { |t| add(t) }
    end

    def add(tool)
      @tools[tool.name] = tool
      self
    end
    alias << add

    def [](name)
      @tools[name.to_s]
    end

    def each(&block)
      @tools.values.each(&block)
    end

    def empty?
      @tools.empty?
    end

    def names
      @tools.keys
    end

    # Provider-neutral schemas for every tool, in declared order.
    def to_schema
      @tools.values.map(&:to_schema)
    end
  end
end
