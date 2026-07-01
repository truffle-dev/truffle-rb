# frozen_string_literal: true

require "test_helper"

# Reference outputs were captured from pi's `shortHash`
# (packages/ai/src/utils/hash.ts) run under Node over this exact input set. The
# port must reproduce them byte for byte, since pi bakes shortHash output into
# tool-call and message ids the OpenAI Responses API then round-trips.
class TestShortHash < Minitest::Test
  include Truffle

  REFERENCE = {
    "" => "k4n83c7h0j2b",
    "a" => "m8735310ae7sx",
    "ab" => "m1bnh312fly6q",
    "abc" => "y0biex7f9bbh",
    "hello" => "1h6qa0qrowduu",
    "hello world" => "n7rb4n1m39uz8",
    "Hello, World!" => "1r5jexi1bwk9ze",
    "0" => "1t916k51bg9odz",
    "123456789" => "1lnucyo2p83ix",
    "call_abc123" => "sb0y391xa16ki",
    "fc_xyz" => "lzngp21n9rgtu",
    "msg_0001" => "1ccrxat16fb4bo",
    "The quick brown fox jumps over the lazy dog" => "eig47k1th3xf1",
    "tool_call_id|with|pipes" => "9gkd2c1hqnpxd",
    "\n\t " => "1ft35z2nknwee",
    "line1\nline2\r\nline3" => "4rj1epz8p7j7",
    "  leading and trailing  " => "1pqdyzq1va7yoj",
    "UPPER_lower_123_!@#$%" => "1q7a69muh7i7m",
    "\u0000\u0001\u001f" => "2ytv0f11c6mv8",
    "\uFFFF" => "gxnfhtpaugc2"
  }.freeze

  # Non-BMP inputs are the important ones: JavaScript `charCodeAt` walks UTF-16
  # code units, so an emoji contributes two surrogate halves. A byte-based or
  # code-point-based port would diverge here.
  UNICODE_REFERENCE = {
    "café" => "1bgmwb2kxwh47",
    "naïve résumé" => "1sn3b11e7ive0",
    "日本語" => "1spw6so10a4hd",
    "emoji: 😀" => "1hwfu9tn4zl2y",
    "🎉🎈🎊" => "l7fpri7rvy0n",
    "mix 😀 café 日本" => "16w2p4s4u72k9"
  }.freeze

  def test_matches_reference_outputs
    REFERENCE.each do |input, expected|
      assert_equal(expected, ShortHash.of(input), "shortHash(#{input.inspect})")
    end
  end

  def test_matches_reference_outputs_for_unicode
    UNICODE_REFERENCE.each do |input, expected|
      assert_equal(expected, ShortHash.of(input), "shortHash(#{input.inspect})")
    end
  end

  def test_long_input_of_sixty_four_bytes
    assert_equal("1r2u3vs17pvraw", ShortHash.of("a" * 64))
  end

  def test_long_input_of_a_thousand_bytes
    assert_equal("kli8eammh8ym", ShortHash.of("a" * 1000))
  end

  def test_is_deterministic
    assert_equal(ShortHash.of("call_abc123"), ShortHash.of("call_abc123"))
  end

  def test_distinct_inputs_hash_differently
    refute_equal(ShortHash.of("fc_xyz"), ShortHash.of("fc_xyw"))
  end

  def test_output_is_base36
    REFERENCE.each_value do |output|
      assert_match(/\A[0-9a-z]+\z/, output)
    end
  end
end
