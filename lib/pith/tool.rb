# frozen_string_literal: true

module Pith
  # A tool the agent can call.
  #
  # A tool is a name, a human-readable description (the model reads this to
  # decide when to call it), a JSON-Schema parameter spec, and a callable that
  # actually runs. Build one with the block DSL:
  #
  #   weather = Pith::Tool.define("get_weather", "Look up the weather for a city") do
  #     param :city, :string, "City name, e.g. 'Berlin'", required: true
  #     param :units, :string, "celsius or fahrenheit"
  #     run { |city:, units: "celsius"| WeatherApi.fetch(city, units) }
  #   end
  #
  # The block runs in a small builder context so `param` and `run` read cleanly.
  class Tool
    attr_reader :name, :description, :parameters, :handler

    def initialize(name:, description:, parameters:, handler:)
      @name = name.to_s
      @description = description.to_s
      @parameters = parameters
      @handler = handler
    end

    def self.define(name, description, &block)
      builder = Builder.new
      builder.instance_eval(&block) if block
      new(
        name: name,
        description: description,
        parameters: builder.schema,
        handler: builder.handler
      )
    end

    # Run the tool. `arguments` is a Hash with string keys (as the model emits);
    # they are symbolized so the handler can use keyword arguments.
    def call(arguments)
      kwargs = (arguments || {}).each_with_object({}) { |(k, v), h| h[k.to_sym] = v }
      result = handler.call(**kwargs)
      result.is_a?(String) ? result : result.inspect
    end

    # JSON-Schema-shaped function spec, provider-neutral. Providers wrap this in
    # whatever envelope they need (OpenAI: {type:"function", function:{...}}).
    def to_schema
      {
        name: name,
        description: description,
        parameters: parameters
      }
    end

    # Collects param declarations and the run block into a JSON Schema + handler.
    class Builder
      attr_reader :handler

      def initialize
        @properties = {}
        @required = []
        @handler = ->(**) { "" }
      end

      def param(name, type, description = nil, required: false, **extra)
        spec = { type: type.to_s }
        spec[:description] = description if description
        spec.merge!(extra)
        @properties[name.to_s] = spec
        @required << name.to_s if required
        self
      end

      def run(&block)
        raise ArgumentError, "run requires a block" unless block

        @handler = block
      end

      def schema
        {
          type: "object",
          properties: @properties,
          required: @required
        }
      end
    end
  end
end
