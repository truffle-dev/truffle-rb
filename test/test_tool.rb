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

  def test_call_coerces_arguments_toward_schema_types
    tool = Truffle::Tool.define("normalize", "Normalize model JSON arguments") do
      param :age, :integer, required: true
      param :enabled, :boolean, required: true
      param :external_id, :string, required: true
      run do |age:, enabled:, external_id:|
        { age: age, enabled: enabled, external_id: external_id }
      end
    end
    arguments = { "age" => "42", "enabled" => "true", "external_id" => 7 }

    assert_equal '{"age":42,"enabled":true,"external_id":"7"}', tool.call(arguments)
    assert_equal({ "age" => "42", "enabled" => "true", "external_id" => 7 }, arguments)
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
    refute_empty box
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

  def test_missing_required_param_returns_model_readable_error
    assert_equal "missing keyword: b", @add.call("a" => 2)
  end

  def test_unknown_param_returns_model_readable_error
    assert_equal "unknown keyword: c", @add.call("a" => 2, "b" => 3, "c" => 4)
  end

  def test_unknown_param_is_allowed_when_handler_accepts_keyrest
    tool = Truffle::Tool.define("flex", "Accept extra keywords") do
      param :name, :string, required: true
      run { |name:, **rest| { name: name, rest: rest } }
    end

    assert_equal '{"name":"sam","rest":{"nickname":"s"}}',
                 tool.call("name" => "sam", "nickname" => "s")
  end

  def test_keyrest_handler_can_prepare_missing_optional_keyword
    tool = Truffle::Tool.define("legacy", "Fold a legacy shape") do
      param :path, :string, required: true
      param :edits, :array, required: true
      run { |path:, edits: nil, **legacy| { path: path, edits: edits || [legacy] } }
    end

    assert_equal '{"path":"a.txt","edits":[{"oldText":"old","newText":"new"}]}',
                 tool.call("path" => "a.txt", "oldText" => "old", "newText" => "new")
  end

  def test_handler_argument_errors_still_propagate
    tool = Truffle::Tool.define("boom", "Raise inside the handler") do
      param :value, :integer, required: true
      run { |value:| raise ArgumentError, "bad value #{value}" }
    end

    error = assert_raises(ArgumentError) { tool.call("value" => 3) }

    assert_equal "bad value 3", error.message
  end

  def test_string_result_passes_through_verbatim
    # A handler that formats its own output is handed to the model as-is, not
    # JSON-quoted, so existing string-returning tools keep working.
    echo = Truffle::Tool.define("echo", "Echo a line") do
      run { "plain text, not \"quoted\"" }
    end

    assert_equal "plain text, not \"quoted\"", echo.call({})
  end

  def test_hash_result_is_serialized_as_json
    lookup = Truffle::Tool.define("lookup", "Return a record") do
      run { { city: "Berlin", population: 3_700_000, capital: true } }
    end

    assert_equal '{"city":"Berlin","population":3700000,"capital":true}', lookup.call({})
  end

  def test_array_result_is_serialized_as_json
    listing = Truffle::Tool.define("listing", "Return rows") do
      run { [{ id: 1, name: "a" }, { id: 2, name: "b" }] }
    end

    assert_equal '[{"id":1,"name":"a"},{"id":2,"name":"b"}]', listing.call({})
  end

  def test_nested_structure_serializes_as_json_not_inspect
    # Ruby's inspect would yield `{:ok=>true, ...}`; the model needs valid JSON.
    nested = Truffle::Tool.define("nested", "Return nested data") do
      run { { ok: true, items: [1, 2], meta: { kind: "list" } } }
    end

    assert_equal '{"ok":true,"items":[1,2],"meta":{"kind":"list"}}', nested.call({})
    refute_includes nested.call({}), "=>"
  end

  def test_scalar_result_serializes_as_json
    answer = Truffle::Tool.define("answer", "Return a number") do
      run { 42 }
    end
    flag = Truffle::Tool.define("flag", "Return a boolean") do
      run { false }
    end

    assert_equal "42", answer.call({})
    assert_equal "false", flag.call({})
  end

  def test_tool_defaults_to_parallel_execution_mode
    tool = Truffle::Tool.define("noop", "Noop") { run { "ok" } }

    assert_equal :parallel, tool.execution_mode
  end

  def test_tool_accepts_sequential_execution_mode
    tool = Truffle::Tool.define("write", "Write a file", execution_mode: :sequential) do
      run { "ok" }
    end

    assert_equal :sequential, tool.execution_mode
  end

  def test_tool_rejects_unknown_execution_mode
    error = assert_raises(ArgumentError) do
      Truffle::Tool.define("noop", "Noop", execution_mode: :sideways) { run { "ok" } }
    end

    assert_match(/unknown tool execution mode :sideways/, error.message)
  end

  def test_tool_rejects_nil_execution_mode
    error = assert_raises(ArgumentError) do
      Truffle::Tool.define("noop", "Noop", execution_mode: nil) { run { "ok" } }
    end

    assert_match(/unknown tool execution mode nil/, error.message)
  end

  def test_unrepresentable_value_falls_back_to_string
    # Infinity and NaN are not valid JSON; JSON.generate raises on them, so the
    # result falls back to its plain string form rather than crashing the loop.
    infinite = Truffle::Tool.define("infinite", "Return infinity") do
      run { Float::INFINITY }
    end

    assert_equal "Infinity", infinite.call({})
  end
end
