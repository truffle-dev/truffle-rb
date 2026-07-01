# frozen_string_literal: true

module Truffle
  # Best-effort coercion of a parsed value toward the types a JSON-Schema
  # declares, run before validation. Models return tool arguments as JSON, and
  # JSON has no integers-versus-numbers distinction and no way to say "the
  # string \"true\" means the boolean true". A schema that asks for an integer
  # or a boolean often receives a string or a float. This mirrors pi's
  # coercion layer: nudge each value toward its declared type when the nudge is
  # unambiguous, and otherwise leave it untouched so validation can report a
  # real mismatch.
  #
  #   schema = { type: "object", properties: { age: { type: "integer" } } }
  #   Truffle::SchemaCoercion.coerce({ "age" => "42" }, schema)
  #   # => { "age" => 42 }
  #
  # Coercion never mutates the argument: the value is deep-copied on entry.
  # It only ever moves a value toward a declared type; it does not add missing
  # properties, drop extra ones, or otherwise reshape the data. A value that
  # already matches, or that cannot be coerced without guessing, is returned
  # unchanged. Union types (anyOf/oneOf) pick the first member whose coerced
  # form validates against Schema, falling back to the original value.
  module SchemaCoercion
    module_function

    # Coerce `value` toward `schema`. `schema` may be a Truffle::Schema or a
    # raw JSON-Schema hash. A non-hash schema (nothing to coerce toward)
    # returns the value untouched.
    def coerce(value, schema)
      spec = schema.respond_to?(:to_h) ? schema.to_h : schema
      return value unless spec.is_a?(Hash)

      coerce_node(deep_dup(value), spec)
    end

    # Fold the compound keywords, then the declared types, over one node.
    # allOf composes left to right; anyOf/oneOf resolve through the first
    # validating member; a scalar type nudges the value once; object and array
    # types recurse into their children.
    def coerce_node(value, schema)
      next_value = value

      Array(node_get(schema, :allOf)).each do |nested|
        next_value = coerce_node(next_value, nested) if nested.is_a?(Hash)
      end

      union = node_get(schema, :anyOf)
      next_value = coerce_union(next_value, union) if union.is_a?(Array)

      one_of = node_get(schema, :oneOf)
      next_value = coerce_union(next_value, one_of) if one_of.is_a?(Array)

      types = schema_types(schema)
      next_value = coerce_scalar(next_value, types) unless types.empty?

      coerce_object(next_value, schema) if types.include?("object") && next_value.is_a?(Hash)
      coerce_array(next_value, schema) if types.include?("array") && next_value.is_a?(Array)

      next_value
    end

    # A value already matching one member of a union type is left alone; a
    # single-type node, or a union no member matches, tries each declared type
    # and keeps the first coercion that actually changes the value.
    def coerce_scalar(value, types)
      return value if types.length > 1 && types.any? { |type| matches_json_type?(value, type) }

      types.each do |type|
        candidate = coerce_primitive(value, type)
        return candidate unless candidate.equal?(value)
      end
      value
    end

    # Try each union member in order: coerce a fresh copy toward it and keep
    # the first whose result validates. If none validate, the value is left as
    # it came in so validation can report against the whole union.
    def coerce_union(value, schemas)
      schemas.each do |schema|
        next unless schema.is_a?(Hash)

        candidate = coerce_node(deep_dup(value), schema)
        return candidate if sub_schema_valid?(schema, candidate)
      end
      value
    end

    # Coerce declared properties present in the value, then, when
    # additionalProperties is itself a schema, coerce every key the properties
    # map did not name.
    def coerce_object(value, schema)
      properties = node_get(schema, :properties)
      defined_keys = properties.is_a?(Hash) ? properties.keys.map(&:to_s) : []

      if properties.is_a?(Hash)
        properties.each do |name, property_schema|
          key = name.to_s
          value[key] = coerce_node(value[key], property_schema) if value.key?(key)
        end
      end

      additional = node_get(schema, :additionalProperties)
      return value unless additional.is_a?(Hash)

      value.each_key do |key|
        next if defined_keys.include?(key.to_s)

        value[key] = coerce_node(value[key], additional)
      end
      value
    end

    # Coerce array elements: a tuple `items` (an array of schemas) matches by
    # index; a single `items` schema applies to every element.
    def coerce_array(value, schema)
      items = node_get(schema, :items)

      if items.is_a?(Array)
        value.each_index do |index|
          item_schema = items[index]
          value[index] = coerce_node(value[index], item_schema) if item_schema.is_a?(Hash)
        end
      elsif items.is_a?(Hash)
        value.each_index { |index| value[index] = coerce_node(value[index], items) }
      end
      value
    end

    # The declared type(s) as a list of strings: a lone type becomes a
    # one-element list, a union type keeps its string members, anything else is
    # empty (nothing to coerce toward).
    def schema_types(schema)
      type = node_get(schema, :type)
      case type
      when String then [type]
      when Array then type.grep(String)
      else []
      end
    end

    def matches_json_type?(value, type)
      case type
      when "number" then value.is_a?(Numeric)
      when "integer" then value.is_a?(Integer)
      when "boolean" then [true, false].include?(value)
      when "string" then value.is_a?(String)
      when "null" then value.nil?
      when "array" then value.is_a?(Array)
      when "object" then value.is_a?(Hash)
      else false
      end
    end

    # Nudge one scalar toward a declared type, but only when the nudge is
    # unambiguous. Ambiguous or already-correct values return the same object
    # (checked with #equal? by the caller), which is how coerce_scalar knows a
    # type did not apply.
    def coerce_primitive(value, type)
      case type
      when "number" then coerce_number(value)
      when "integer" then coerce_integer(value)
      when "boolean" then coerce_boolean(value)
      when "string" then coerce_string(value)
      when "null" then coerce_null(value)
      else value
      end
    end

    def coerce_number(value)
      return 0 if value.nil?

      if value.is_a?(String) && !value.strip.empty?
        parsed = parse_number(value)
        return parsed unless parsed.nil?
      end
      return value ? 1 : 0 if boolean?(value)

      value
    end

    def coerce_integer(value)
      return 0 if value.nil?

      if value.is_a?(String) && !value.strip.empty?
        parsed = parse_number(value)
        return parsed if parsed.is_a?(Integer)
      end
      return value ? 1 : 0 if boolean?(value)

      value
    end

    def coerce_boolean(value)
      return false if value.nil?

      if value.is_a?(String)
        return true if value == "true"
        return false if value == "false"
      end
      if value.is_a?(Numeric)
        return true if value == 1
        return false if value.zero?
      end
      value
    end

    def coerce_string(value)
      return "" if value.nil?
      return value.to_s if value.is_a?(Numeric) || boolean?(value)

      value
    end

    def coerce_null(value)
      return nil if ["", 0, false].include?(value)

      value
    end

    # Parse a numeric string the way JSON round-trips a number: an integral
    # value collapses to Integer so an "integer" schema sees an Integer, a
    # fractional value stays Float. A non-finite or unparseable string yields
    # nil, meaning "not a number, leave it alone".
    def parse_number(str)
      float = Float(str)
      return nil unless float.finite?

      float == float.to_i ? float.to_i : float
    rescue ArgumentError, TypeError
      nil
    end

    def boolean?(value)
      [true, false].include?(value)
    end

    def sub_schema_valid?(schema, value)
      Truffle::Schema.from_h(schema).valid?(value)
    rescue StandardError
      false
    end

    # Read a structural key tolerant of symbol or string form, matching the
    # mixed keying Schema#to_h emits (symbol structural keys, string property
    # names) and raw hashes a caller might hand in.
    def node_get(schema, key)
      return nil unless schema.is_a?(Hash)
      return schema[key] if schema.key?(key)

      schema[key.to_s]
    end

    def deep_dup(value)
      case value
      when Hash then value.each_with_object({}) { |(k, v), copy| copy[k] = deep_dup(v) }
      when Array then value.map { |element| deep_dup(element) }
      else value
      end
    end
  end
end
