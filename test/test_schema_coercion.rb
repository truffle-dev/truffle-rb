# frozen_string_literal: true

require "test_helper"

# Reference behavior mirrors pi's coercion layer (packages/ai/src/utils/
# validation.ts): tool arguments arrive as JSON, so integers show up as
# strings and booleans show up as "true"/"false", and the coercer nudges each
# value toward its declared type before validation runs. Every case below is
# offline and asserts the same shape the TypeScript coercer produces.
class TestSchemaCoercion < Minitest::Test
  include Truffle

  def coerce(value, schema)
    SchemaCoercion.coerce(value, schema)
  end

  def object_schema(properties, extra = {})
    { type: "object", properties: properties }.merge(extra)
  end

  def test_integer_string_becomes_integer
    schema = object_schema("age" => { type: "integer" })

    assert_equal({ "age" => 42 }, coerce({ "age" => "42" }, schema))
  end

  def test_number_string_becomes_float
    schema = object_schema("ratio" => { type: "number" })
    result = coerce({ "ratio" => "3.14" }, schema)

    assert_in_delta(3.14, result["ratio"])
  end

  def test_integral_number_string_collapses_to_integer
    schema = object_schema("count" => { type: "integer" })

    assert_equal({ "count" => 5 }, coerce({ "count" => "5.0" }, schema))
  end

  def test_boolean_from_string
    schema = object_schema("on" => { type: "boolean" }, "off" => { type: "boolean" })

    assert_equal({ "on" => true, "off" => false },
                 coerce({ "on" => "true", "off" => "false" }, schema))
  end

  def test_boolean_from_number
    schema = object_schema("yes" => { type: "boolean" }, "no" => { type: "boolean" })

    assert_equal({ "yes" => true, "no" => false }, coerce({ "yes" => 1, "no" => 0 }, schema))
  end

  def test_string_from_number_and_boolean
    schema = object_schema("id" => { type: "string" }, "flag" => { type: "string" })

    assert_equal({ "id" => "7", "flag" => "true" }, coerce({ "id" => 7, "flag" => true }, schema))
  end

  def test_null_from_empty_string_zero_and_false
    schema = object_schema(
      "a" => { type: "null" }, "b" => { type: "null" }, "c" => { type: "null" }
    )

    assert_equal({ "a" => nil, "b" => nil, "c" => nil },
                 coerce({ "a" => "", "b" => 0, "c" => false }, schema))
  end

  def test_number_and_integer_from_nil_default_to_zero
    schema = object_schema("n" => { type: "number" }, "i" => { type: "integer" })

    assert_equal({ "n" => 0, "i" => 0 }, coerce({ "n" => nil, "i" => nil }, schema))
  end

  def test_string_from_nil_defaults_to_empty
    schema = object_schema("s" => { type: "string" })

    assert_equal({ "s" => "" }, coerce({ "s" => nil }, schema))
  end

  def test_boolean_from_nil_defaults_to_false
    schema = object_schema("b" => { type: "boolean" })

    assert_equal({ "b" => false }, coerce({ "b" => nil }, schema))
  end

  def test_uncoercible_string_left_alone
    schema = object_schema("age" => { type: "integer" })

    assert_equal({ "age" => "not a number" }, coerce({ "age" => "not a number" }, schema))
  end

  def test_blank_string_not_coerced_to_number
    schema = object_schema("n" => { type: "number" })

    assert_equal({ "n" => "   " }, coerce({ "n" => "   " }, schema))
  end

  def test_already_correct_values_pass_through
    schema = object_schema("age" => { type: "integer" }, "name" => { type: "string" })
    input = { "age" => 30, "name" => "Ada" }

    assert_equal({ "age" => 30, "name" => "Ada" }, coerce(input, schema))
  end

  def test_nested_object_coercion
    schema = object_schema(
      "user" => object_schema("age" => { type: "integer" })
    )

    assert_equal({ "user" => { "age" => 9 } }, coerce({ "user" => { "age" => "9" } }, schema))
  end

  def test_array_single_items_coercion
    schema = object_schema("ids" => { type: "array", items: { type: "integer" } })

    assert_equal({ "ids" => [1, 2, 3] }, coerce({ "ids" => %w[1 2 3] }, schema))
  end

  def test_array_tuple_items_coercion
    schema = object_schema(
      "pair" => { type: "array", items: [{ type: "integer" }, { type: "boolean" }] }
    )

    assert_equal({ "pair" => [4, true] }, coerce({ "pair" => %w[4 true] }, schema))
  end

  def test_additional_properties_coercion
    schema = {
      type: "object",
      properties: { "known" => { type: "string" } },
      additionalProperties: { type: "integer" }
    }
    result = coerce({ "known" => 5, "extra" => "10" }, schema)

    assert_equal({ "known" => "5", "extra" => 10 }, result)
  end

  def test_missing_property_is_not_added
    schema = object_schema("age" => { type: "integer" })

    assert_equal({}, coerce({}, schema))
  end

  def test_extra_property_without_additional_schema_left_alone
    schema = object_schema("known" => { type: "string" })

    assert_equal({ "known" => "5", "extra" => "10" },
                 coerce({ "known" => 5, "extra" => "10" }, schema))
  end

  def test_any_of_picks_validating_member
    schema = object_schema(
      "value" => { anyOf: [{ type: "integer" }, { type: "boolean" }] }
    )

    assert_equal({ "value" => 12 }, coerce({ "value" => "12" }, schema))
  end

  def test_one_of_picks_validating_member
    schema = object_schema(
      "value" => { oneOf: [{ type: "integer" }, { type: "boolean" }] }
    )

    assert_equal({ "value" => 9 }, coerce({ "value" => "9" }, schema))
  end

  def test_one_of_falls_back_to_original_when_no_member_validates
    schema = object_schema(
      "value" => { oneOf: [{ type: "integer" }, { type: "boolean" }] }
    )

    assert_equal({ "value" => "words" }, coerce({ "value" => "words" }, schema))
  end

  def test_all_of_folds_left_to_right
    schema = object_schema(
      "value" => { allOf: [{ type: "integer" }] }
    )

    assert_equal({ "value" => 3 }, coerce({ "value" => "3" }, schema))
  end

  def test_union_type_leaves_matching_member_untouched
    schema = object_schema("value" => { type: %w[string null] })

    assert_equal({ "value" => "" }, coerce({ "value" => "" }, schema))
  end

  def test_union_type_coerces_when_no_member_matches
    schema = object_schema("value" => { type: %w[integer boolean] })

    assert_equal({ "value" => 8 }, coerce({ "value" => "8" }, schema))
  end

  def test_does_not_mutate_input
    schema = object_schema("age" => { type: "integer" },
                           "tags" => { type: "array",
                                       items: { type: "integer" } })
    input = { "age" => "1", "tags" => ["2"] }
    coerce(input, schema)

    assert_equal({ "age" => "1", "tags" => ["2"] }, input)
  end

  def test_non_finite_number_string_left_alone
    schema = object_schema("n" => { type: "integer" })

    assert_equal({ "n" => "1e400" }, coerce({ "n" => "1e400" }, schema))
  end

  def test_string_keyed_structural_keys_are_matched
    schema = { "type" => "object", "properties" => { "age" => { "type" => "integer" } } }

    assert_equal({ "age" => 5 }, coerce({ "age" => "5" }, schema))
  end

  def test_accepts_truffle_schema_instance
    schema = Schema.build do
      param :age, :integer, required: true
    end

    assert_equal({ "age" => 42 }, coerce({ "age" => "42" }, schema))
  end

  def test_non_hash_schema_returns_value_untouched
    assert_equal("unchanged", coerce("unchanged", "not a schema"))
  end

  def test_symbol_keyed_property_names_are_matched
    schema = { type: "object", properties: { age: { type: "integer" } } }

    assert_equal({ "age" => 7 }, coerce({ "age" => "7" }, schema))
  end
end
