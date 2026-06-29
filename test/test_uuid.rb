# frozen_string_literal: true

require_relative "test_helper"

module Truffle
  class TestUUID < Minitest::Test
    def test_v7_has_canonical_hyphenated_shape
      id = UUID.v7

      assert_match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/, id)
    end

    def test_v7_version_nibble_is_seven
      id = UUID.v7
      # The version lives in the first nibble of the third group.
      version_nibble = id.split("-")[2][0]

      assert_equal "7", version_nibble
    end

    def test_v7_variant_bits_are_rfc_variant
      id = UUID.v7
      # The variant lives in the high bits of the first nibble of the fourth
      # group: 0b10xx, so the nibble is one of 8, 9, a, b.
      variant_nibble = id.split("-")[3][0]

      assert_includes %w[8 9 a b], variant_nibble
    end

    def test_v7_encodes_the_timestamp_in_the_high_bits
      now = Time.utc(2026, 6, 29, 12, 0, 0)
      id = UUID.v7(now: now)

      ms = (now.to_f * 1000).floor
      high48 = id.delete("-")[0, 12].to_i(16)

      assert_equal ms, high48
    end

    def test_v7_sorts_in_creation_order
      earlier = UUID.v7(now: Time.utc(2026, 1, 1))
      later = UUID.v7(now: Time.utc(2026, 12, 31))

      assert_operator earlier, :<, later
    end

    def test_short_returns_eight_hex_chars
      id = UUID.short({})

      assert_match(/\A\h{8}\z/, id)
    end

    def test_short_avoids_ids_already_taken
      taken = {}
      first = UUID.short(taken)
      taken[first] = true
      second = UUID.short(taken)

      refute_equal first, second
    end
  end
end
