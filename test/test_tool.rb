# frozen_string_literal: true

require "test_helper"

class TestTool < Minitest::Test
  def setup
    @add = Truffle::Tool.define("add", "Add two integers") do
      param :a, :integer, "first addend", required: true
      param :b, :integer, "second addend", required: true
      run { |a:, b:| a + b }
    end
  end

  def test_schema_shape
    schema = @add.to_schema
    assert_equal "add", schema[:name]
    assert_equal "Add two integers", schema[:description]
    assert_equal "object", schema[:parameters][:type]
    assert_equal %w[a b], schema[:parameters][:required]
    assert_equal "integer", schema[:parameters][:properties]["a"][:type]
    assert_equal "first addend", schema[:parameters][:properties]["a"][:description]
  end

  def test_call_symbolizes_string_keys
    # The model emits string keys; the handler uses keyword args.
    assert_equal "5", @add.call("a" => 2, "b" => 3)
  end

  def test_call_returns_string
    result = @add.call("a" => 10, "b" => 20)
    assert_kind_of String, result
    assert_equal "30", result
  end

  def test_toolbox_lookup_and_schema
    box = Truffle::Toolbox.new([@add])
    assert_equal @add, box["add"]
    assert_equal ["add"], box.names
    assert_equal 1, box.to_schema.length
    refute box.empty?
  end

  def test_optional_param_with_default
    greet = Truffle::Tool.define("greet", "Greet someone") do
      param :name, :string, required: true
      param :loud, :boolean
      run { |name:, loud: false| loud ? "HELLO #{name.upcase}" : "hello #{name}" }
    end
    assert_equal "hello sam", greet.call("name" => "sam")
    assert_equal "HELLO SAM", greet.call("name" => "sam", "loud" => true)
    refute_includes greet.to_schema[:parameters][:required], "loud"
  end
end
