# frozen_string_literal: true

require_relative "test_helper"
require "json"

# Covers Truffle::Schema, the JSON-Schema value object built by the block DSL.
# Every case asserts the emitted hash shape, so the provider seam and the
# structured-response accessor that build on it have a stable contract.
class TestSchema < Minitest::Test
  def test_empty_schema_is_an_open_object
    schema = Truffle::Schema.build

    assert_equal({ type: "object", properties: {}, required: [] }, schema.to_h)
  end

  def test_scalar_params_carry_type_and_description
    schema = Truffle::Schema.build do
      param :name, :string, "Full name", required: true
      param :age, :integer
    end

    assert_equal(
      {
        type: "object",
        properties: {
          "name" => { type: "string", description: "Full name" },
          "age" => { type: "integer" }
        },
        required: ["name"]
      },
      schema.to_h
    )
  end

  def test_required_lists_only_params_marked_required
    schema = Truffle::Schema.build do
      param :a, :string, required: true
      param :b, :string
      param :c, :integer, required: true
    end

    assert_equal %w[a c], schema.to_h[:required]
  end

  def test_enum_and_passthrough_constraints_are_emitted
    schema = Truffle::Schema.build do
      param :unit, :string, enum: %w[celsius fahrenheit]
      param :score, :number, minimum: 0, maximum: 100
    end

    props = schema.to_h[:properties]

    assert_equal(%w[celsius fahrenheit], props["unit"][:enum])
    assert_equal(0, props["score"][:minimum])
    assert_equal(100, props["score"][:maximum])
  end

  def test_nested_object_block_builds_its_own_properties_and_required
    schema = Truffle::Schema.build do
      param :address, :object, required: true do
        param :city, :string, required: true
        param :zip, :string
      end
    end

    address = schema.to_h[:properties]["address"]

    assert_equal "object", address[:type]
    assert_equal(%w[city zip], address[:properties].keys)
    assert_equal ["city"], address[:required]
    assert_equal ["address"], schema.to_h[:required]
  end

  def test_bare_object_without_a_block_is_an_open_object_node
    schema = Truffle::Schema.build do
      param :meta, :object
    end

    assert_equal({ type: "object", properties: {}, required: [] },
                 schema.to_h[:properties]["meta"])
  end

  def test_array_of_scalars_uses_an_items_type
    schema = Truffle::Schema.build do
      param :tags, :array, items: :string
    end

    assert_equal({ type: "array", items: { type: "string" } },
                 schema.to_h[:properties]["tags"])
  end

  def test_array_block_builds_an_element_object
    schema = Truffle::Schema.build do
      param :rows, :array do
        param :id, :integer, required: true
      end
    end

    rows = schema.to_h[:properties]["rows"]

    assert_equal "array", rows[:type]
    assert_equal({ type: "object", properties: { "id" => { type: "integer" } }, required: ["id"] },
                 rows[:items])
  end

  def test_array_items_accepts_a_prebuilt_schema
    inner = Truffle::Schema.build { param :v, :string, required: true }
    schema = Truffle::Schema.build do
      param :rows, :array, items: inner
    end

    assert_equal inner.to_h, schema.to_h[:properties]["rows"][:items]
  end

  def test_array_without_items_or_block_raises
    error = assert_raises(ArgumentError) do
      Truffle::Schema.build { param :tags, :array }
    end
    assert_match(/array param requires/, error.message)
  end

  def test_to_h_is_deeply_frozen
    schema = Truffle::Schema.build do
      param :address, :object, required: true do
        param :city, :string
      end
    end

    assert_predicate schema.to_h, :frozen?
    assert_predicate schema.to_h[:properties], :frozen?
    assert_predicate schema.to_h[:properties]["address"][:properties], :frozen?
    assert_raises(FrozenError) { schema.to_h[:required] << "mutated" }
  end

  def test_build_does_not_freeze_a_caller_passed_constraint
    values = %w[a b]
    Truffle::Schema.build { param :choice, :string, enum: values }

    refute_predicate values, :frozen?
  end

  def test_from_h_round_trips_a_symbol_keyed_hash
    schema = Truffle::Schema.build do
      param :name, :string, required: true
      param :tags, :array, items: :string
    end

    assert_equal schema, Truffle::Schema.from_h(schema.to_h)
  end

  def test_from_h_normalizes_string_keys_after_a_json_round_trip
    schema = Truffle::Schema.build do
      param :name, :string, "Full name", required: true
      param :address, :object, required: true do
        param :city, :string, required: true
      end
      param :rows, :array do
        param :id, :integer, required: true
      end
    end

    json = JSON.parse(JSON.generate(schema.to_h))

    assert_equal schema, Truffle::Schema.from_h(json)
  end

  def test_from_h_normalizes_symbol_property_names_and_required_entries
    # A hand-built hash may carry symbol property names and symbol entries in
    # `required`; from_h folds both to the string form to_h emits, so it equals
    # the schema the DSL would build.
    built = Truffle::Schema.build do
      param :name, :string, required: true
      param :age, :integer
    end
    hand = Truffle::Schema.from_h(
      type: :object,
      properties: { name: { type: :string }, age: { type: :integer } },
      required: [:name]
    )

    assert_equal built, hand
    assert_equal(%w[name age], hand.to_h[:properties].keys)
    assert_equal(["name"], hand.to_h[:required])
  end

  def test_equality_and_hash_track_the_definition
    a = Truffle::Schema.build { param :x, :string, required: true }
    b = Truffle::Schema.build { param :x, :string, required: true }
    c = Truffle::Schema.build { param :x, :integer, required: true }

    assert_equal a, b
    assert_equal a.hash, b.hash
    refute_equal a, c
    assert a.eql?(b)
  end

  def test_schemas_are_usable_as_hash_keys
    a = Truffle::Schema.build { param :x, :string }
    b = Truffle::Schema.build { param :x, :string }
    store = { a => "value" }

    assert_equal "value", store[b]
  end
end
