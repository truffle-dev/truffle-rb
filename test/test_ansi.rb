# frozen_string_literal: true

require "test_helper"

class TestAnsi < Minitest::Test
  include Truffle

  def test_returns_plain_string_unchanged
    assert_equal "hello world", Ansi.strip("hello world")
  end

  def test_no_escape_fast_path_returns_the_same_object
    plain = "no escapes here".dup

    assert_same plain, Ansi.strip(plain)
  end

  def test_strips_a_simple_color_sequence
    assert_equal "red", Ansi.strip("\e[31mred\e[0m")
  end

  def test_strips_multi_parameter_sequence
    assert_equal "x", Ansi.strip("\e[1;32mx\e[0m")
  end

  def test_strips_colon_separated_parameters
    assert_equal "x", Ansi.strip("\e[38:5:200mx\e[0m")
  end

  def test_strips_cursor_and_clear_sequences
    assert_equal "clear", Ansi.strip("\e[2J\e[Hclear")
  end

  def test_strips_eight_bit_csi_introducer
    assert_equal "X", Ansi.strip("\u009B31mX")
  end

  def test_strips_osc_terminated_by_bel
    assert_equal "text", Ansi.strip("\e]0;window title\atext")
  end

  def test_strips_osc_terminated_by_escape_backslash
    assert_equal "text", Ansi.strip("\e]0;window title\e\\text")
  end

  def test_osc_is_non_greedy_between_two_sequences
    # Two OSC hyperlink sequences: a greedy match would swallow "LINK" between
    # the first terminator and the second sequence.
    assert_equal "LINKdone", Ansi.strip("\e]8;;https://example.com\aLINK\e]8;;\adone")
  end

  def test_preserves_newlines_and_surrounding_text
    assert_equal "line1\nline2\n", Ansi.strip("line1\n\e[31mline2\e[0m\n")
  end

  def test_strips_several_sequences_in_one_string
    assert_equal "ab", Ansi.strip("\e[31ma\e[0m\e[1mb\e[0m")
  end

  def test_empty_string
    assert_equal "", Ansi.strip("")
  end

  def test_raises_type_error_on_nil
    assert_raises(TypeError) { Ansi.strip(nil) }
  end

  def test_raises_type_error_on_non_string
    assert_raises(TypeError) { Ansi.strip(42) }
  end
end
