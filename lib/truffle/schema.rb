# frozen_string_literal: true

module Truffle
  # An immutable JSON-Schema value object for structured output, built by a block
  # DSL that mirrors Tool::Builder's `param`. It describes the shape a model
  # should return so a provider can ask for native structured output and a caller
  # can validate the result.
  #
  #   schema = Truffle::Schema.build do
  #     param :name, :string, "Full name", required: true
  #     param :age, :integer, required: true
  #     param :unit, :string, enum: %w[celsius fahrenheit]
  #     param :tags, :array, items: :string
  #     param :address, :object, required: true do
  #       param :city, :string, required: true
  #     end
  #   end
  #
  #   schema.to_h
  #   # => {type: "object", properties: {...}, required: ["name", "age", "address"]}
  #
  # The emitted hash is the JSON-Schema subset the three providers accept: an
  # object root with `properties`/`required`, scalar fields (string, integer,
  # number, boolean, null), nested objects, and arrays with an `items` schema.
  # `$ref`/`$defs` are out of scope. The value is provider-neutral; the provider
  # seam wraps it in whatever envelope each API needs.
  class Schema
    # The canonical structural keys, the order they are emitted in, and the keys
    # whose values are themselves schema nodes (recursed during normalization).
    NODE_KEYS = %i[type description enum required properties items].freeze

    attr_reader :definition

    # Build a schema from a block in the DSL context. An empty block yields an
    # object schema with no properties.
    def self.build(&block)
      builder = Builder.new
      builder.instance_eval(&block) if block

      new(builder.to_definition)
    end

    # Rebuild a schema from the hash #to_h produced, the inverse used after a
    # JSON round-trip. Keys may be symbols (a direct #to_h) or strings (post
    # JSON); both fold to the canonical symbol-keyed form, so from_h(to_h) is an
    # identity and equality survives the trip.
    def self.from_h(hash)
      new(normalize_node(hash))
    end

    def initialize(definition)
      @definition = deep_freeze(deep_dup(definition))
    end

    # The provider-neutral JSON-Schema hash. Structural keys are symbols and
    # property names are strings, matching Tool#parameters so a schema drops into
    # the same places a tool's parameter spec does.
    def to_h
      @definition
    end

    def ==(other)
      other.is_a?(Schema) && other.definition == @definition
    end
    alias eql? ==

    def hash
      [self.class, @definition].hash
    end

    # Fold a schema node's keys to symbols, recursing into `properties` values
    # and an `items` subschema, and coercing `required` entries to strings. A
    # non-Hash (an enum value, a leaf) is returned untouched.
    def self.normalize_node(node)
      return node unless node.is_a?(Hash)

      node.each_with_object({}) do |(key, value), result|
        symbol = key.to_sym
        result[symbol] =
          case symbol
          when :type then normalize_type(value)
          when :properties then normalize_properties(value)
          when :items then normalize_node(value)
          when :required then Array(value).map(&:to_s)
          else value
          end
      end
    end

    # Coerce a `type` value to the string form to_h emits. A union type is a
    # list, so each member folds; a single type folds on its own.
    def self.normalize_type(value)
      value.is_a?(Array) ? value.map(&:to_s) : value.to_s
    end

    # Fold a properties map: property names stay strings, each value is a node.
    def self.normalize_properties(properties)
      return properties unless properties.is_a?(Hash)

      properties.each_with_object({}) do |(name, spec), result|
        result[name.to_s] = normalize_node(spec)
      end
    end

    private

    def deep_dup(value)
      case value
      when Hash then value.each_with_object({}) { |(k, v), h| h[k] = deep_dup(v) }
      when Array then value.map { |element| deep_dup(element) }
      else value
      end
    end

    def deep_freeze(value)
      case value
      when Hash then value.each_value { |v| deep_freeze(v) }
      when Array then value.each { |element| deep_freeze(element) }
      end
      value.freeze
    end

    # Collects `param` declarations into the object-schema shape. Nested objects
    # and array item objects each get their own Builder, so the DSL nests without
    # any shared state.
    class Builder
      attr_reader :properties, :required

      def initialize
        @properties = {}
        @required = []
      end

      # Declare one property. `type` is a JSON-Schema type symbol or string. A
      # block builds a nested object's properties (for `:object`) or the element
      # object of an array (for `:array`). `items:` gives an array a scalar or
      # prebuilt element schema; `enum:` restricts the values; any other keyword
      # passes through as a constraint (`minimum`, `format`, and the like).
      def param(name, type, description = nil, required: false, enum: nil, items: nil, **extra,
                &block)
        spec = base_spec(type, description, enum, extra)
        apply_compound(spec, type, items, block)
        @properties[name.to_s] = spec
        @required << name.to_s if required
        self
      end

      # The object schema this builder has collected.
      def to_definition
        { type: "object", properties: @properties, required: @required }
      end

      private

      # The scalar core of a property spec: the type string, plus the optional
      # description, enum, and any passthrough constraints. The compound shape
      # (object properties, array items) is layered on afterwards.
      def base_spec(type, description, enum, extra)
        spec = { type: type.to_s }
        spec[:description] = description if description
        spec[:enum] = enum if enum
        spec.merge!(extra)
        spec
      end

      # Layer the compound shape onto a base spec: an `:object` gets its nested
      # properties/required, an `:array` gets its `items` schema. A scalar type
      # is left as base_spec built it.
      def apply_compound(spec, type, items, block)
        case type.to_sym
        when :object then spec.merge!(nested_object(block))
        when :array then spec[:items] = array_items(items, block)
        end
      end

      # The properties/required pair for a nested object, empty when no block is
      # given so a bare `:object` still emits a valid (open) object node.
      def nested_object(block)
        return { properties: {}, required: [] } unless block

        nested = Builder.new
        nested.instance_eval(&block)
        { properties: nested.properties, required: nested.required }
      end

      # An array's item schema: a block builds an element object, `items:` takes a
      # type symbol, a prebuilt Schema, or a raw schema Hash.
      def array_items(items, block)
        if block
          nested = Builder.new
          nested.instance_eval(&block)
          { type: "object", properties: nested.properties, required: nested.required }
        elsif items.is_a?(Schema) then items.to_h
        elsif items.is_a?(Hash) then items
        elsif items then { type: items.to_s }
        else
          raise ArgumentError, "array param requires an items: type or a block"
        end
      end
    end
  end
end
