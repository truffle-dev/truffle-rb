# frozen_string_literal: true

require "test_helper"

class TestBinaryOutput < Minitest::Test
  include Truffle

  def test_returns_plain_text_unchanged
    assert_equal "hello world", BinaryOutput.sanitize("hello world")
  end

  def test_keeps_tab_newline_and_carriage_return
    assert_equal "a\tb\nc\rd", BinaryOutput.sanitize("a\tb\nc\rd")
  end

  def test_drops_a_null_byte
    assert_equal "ab", BinaryOutput.sanitize("a\x00b")
  end

  def test_drops_other_c0_controls
    # SOH (0x01) and the top of the C0 range (0x1f) both go.
    assert_equal "ab", BinaryOutput.sanitize("a\x01\x1fb")
  end

  def test_keeps_the_first_printable_after_the_c0_range
    # 0x20 is one past the 0x1f cutoff and survives.
    assert_equal "a b", BinaryOutput.sanitize("a\x20b")
  end

  def test_drops_the_interlinear_annotation_format_characters
    assert_equal "ab", BinaryOutput.sanitize("a\uFFF9\uFFFA\uFFFBb")
  end

  def test_keeps_the_characters_bracketing_the_annotation_range
    assert_equal "a\uFFF8\uFFFCb", BinaryOutput.sanitize("a\uFFF8\uFFFCb")
  end

  def test_keeps_del_and_c1_controls
    # pi's cutoff is <= 0x1f, so DEL (0x7f) and a C1 control (0x9b) are left in.
    assert_equal "a\x7F\u009Bb", BinaryOutput.sanitize("a\x7F\u009Bb")
  end

  def test_empty_string
    assert_equal "", BinaryOutput.sanitize("")
  end

  def test_keeps_multibyte_characters
    assert_equal "café☃", BinaryOutput.sanitize("café☃")
  end
end
