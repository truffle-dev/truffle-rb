# frozen_string_literal: true

require "test_helper"

# The pure prompt-template argument layer for slash commands, ported from pi's
# prompt-templates.ts. It is intentionally small: argument parsing and placeholder
# substitution only. Loading prompt files and executing commands are later slices.
class TestPromptTemplates < Minitest::Test
  PromptTemplates = Truffle::PromptTemplates

  def test_parse_command_args_splits_on_whitespace
    args = PromptTemplates.parse_command_args("one two\tthree\nfour")

    assert_equal %w[one two three four], args
  end

  def test_parse_command_args_groups_single_and_double_quotes
    args = PromptTemplates.parse_command_args(%(one "two words" 'three more'))

    assert_equal ["one", "two words", "three more"], args
  end

  def test_parse_command_args_keeps_unclosed_quote_content
    args = PromptTemplates.parse_command_args(%(one "two words))

    assert_equal ["one", "two words"], args
  end

  def test_substitute_args_replaces_positionals_and_all_arguments
    out = PromptTemplates.substitute_args(
      "first=$1 second=$2 third=$3 all=$@ args=$ARGUMENTS",
      %w[alpha beta]
    )

    assert_equal "first=alpha second=beta third= all=alpha beta args=alpha beta", out
  end

  def test_substitute_args_uses_defaults_for_missing_or_empty_values
    out = PromptTemplates.substitute_args(
      "one=${1:-fallback} two=${2:-fallback} three=${3:-fallback}",
      ["present", ""]
    )

    assert_equal "one=present two=fallback three=fallback", out
  end

  def test_substitute_args_expands_argument_slices
    out = PromptTemplates.substitute_args(
      "tail=${@:2} pair=${@:2:2} zero=${@:0}",
      %w[one two three four]
    )

    assert_equal "tail=two three four pair=two three zero=one two three four", out
  end

  def test_substitute_args_out_of_range_slice_is_empty
    out = PromptTemplates.substitute_args("later=${@:9}", %w[one two])

    assert_equal "later=", out
  end

  def test_substitute_args_is_single_pass
    out = PromptTemplates.substitute_args("$1 ${2:-$1}", ["$2"])

    assert_equal "$2 $1", out
  end
end
