# frozen_string_literal: true

require "json"
require_relative "content"
require_relative "schema"
require_relative "schema_coercion"

module Truffle
  # A tool the agent can call.
  #
  # A tool is a name, a human-readable description (the model reads this to
  # decide when to call it), a JSON-Schema parameter spec, and a callable that
  # actually runs. Build one with the block DSL:
  #
  #   weather = Truffle::Tool.define("get_weather", "Look up the weather for a city") do
  #     param :city, :string, "City name, e.g. 'Berlin'", required: true
  #     param :units, :string, "celsius or fahrenheit"
  #     run { |city:, units: "celsius"| WeatherApi.fetch(city, units) }
  #   end
  #
  # The block runs in a small builder context so `param` and `run` read cleanly.
  class Tool
    EXECUTION_MODES = %i[parallel sequential].freeze

    attr_reader :name, :description, :parameters, :handler, :execution_mode

    def initialize(name:, description:, parameters:, handler:, execution_mode: :parallel,
                   eager_input_streaming: false)
      @name = name.to_s
      @description = description.to_s
      @parameters = parameters
      @handler = handler
      @execution_mode = self.class.normalize_execution_mode(execution_mode)
      # Providers that support it stream this tool's input fragments without
      # server-side JSON buffering — a large argument (a file body) arrives live
      # instead of all at once when generation finishes.
      @eager_input_streaming = eager_input_streaming
    end

    def eager_input_streaming? = @eager_input_streaming

    def self.define(name, description, execution_mode: :parallel, eager_input_streaming: false,
                    &block)
      builder = Builder.new
      builder.instance_eval(&block) if block
      new(
        name: name,
        description: description,
        parameters: builder.schema,
        handler: builder.handler,
        execution_mode: execution_mode,
        eager_input_streaming: eager_input_streaming
      )
    end

    def self.normalize_execution_mode(mode)
      mode = mode.to_sym if mode.respond_to?(:to_sym)
      return mode if EXECUTION_MODES.include?(mode)

      expected = EXECUTION_MODES.inspect
      raise ArgumentError,
            "unknown tool execution mode #{mode.inspect}, expected one of #{expected}"
    end

    # Run the tool. `arguments` is a Hash with string keys (as the model emits);
    # they are symbolized so the handler can use keyword arguments. The handler's
    # return value is serialized for the model by #serialize_result.
    def call(arguments)
      arguments = SchemaCoercion.coerce(arguments || {}, parameters)
      validation_error = validate_arguments(arguments)
      return validation_error if validation_error

      kwargs = arguments.each_with_object({}) { |(k, v), h| h[k.to_sym] = v }
      serialize_result(handler.call(**kwargs))
    end

    # JSON-Schema-shaped function spec, provider-neutral. Providers wrap this in
    # whatever envelope they need (OpenAI: {type:"function", function:{...}}).
    def to_schema
      schema = {
        name: name,
        description: description,
        parameters: parameters
      }
      schema[:eager_input_streaming] = true if eager_input_streaming?
      schema
    end

    private

    def validate_arguments(arguments)
      keys = arguments.keys.map(&:to_s)
      missing = required_parameters - keys
      if !missing.empty? && !handler_can_prepare_missing_required?(missing, keys)
        return "missing keyword: #{missing.first}"
      end

      unknown = keys - property_names
      return nil if unknown.empty? || handler_accepts_unknown_keywords?

      "unknown keyword: #{unknown.first}"
    end

    def required_parameters
      Array(parameters[:required]).map(&:to_s)
    end

    def property_names
      parameters.fetch(:properties, {}).keys.map(&:to_s)
    end

    def handler_accepts_unknown_keywords?
      handler.parameters.any? { |kind, _name| kind == :keyrest }
    end

    def handler_can_prepare_missing_required?(missing, keys)
      return false unless handler_accepts_unknown_keywords?
      return false if (keys - property_names).empty?

      optional_keywords = handler.parameters.filter_map do |kind, name|
        name.to_s if kind == :key
      end
      missing.all? { |name| optional_keywords.include?(name) }
    end

    # The model reads tool output as text. A String result is already that text
    # and passes through unchanged, so a handler that formats its own output
    # keeps working. A Content block (or an array of them) is a multimodal result
    # and passes through too, so a tool can return an image the model sees rather
    # than base64 text. Any other value (a Hash or Array of structured data, or a
    # scalar) is encoded as JSON so the model receives valid JSON rather than
    # Ruby's inspect syntax (`{:a=>1}`), mirroring how pi stringifies a
    # structured tool result with JSON.stringify. A value JSON cannot represent
    # (Infinity, NaN) falls back to its plain string form.
    def serialize_result(result)
      return result if result.is_a?(String) || content_result?(result)

      JSON.generate(result)
    rescue JSON::GeneratorError
      result.to_s
    end

    # Whether a handler returned Content blocks (text/image) to pass through as a
    # multimodal tool result, rather than a value to stringify.
    def content_result?(result)
      blocks = Array(result)
      !blocks.empty? && blocks.all? { |block| block.is_a?(Content::Text) || block.is_a?(Content::Image) }
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
