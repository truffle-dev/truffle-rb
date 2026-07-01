# frozen_string_literal: true

module Truffle
  # Deterministic short hash of a string, ported from pi's `shortHash`
  # (packages/ai/src/utils/hash.ts). pi uses it to fold a long or foreign
  # identifier into a compact token: the OpenAI Responses API rewrites a tool
  # call id it did not issue as `fc_#{ShortHash.of(id)}` and a message id as
  # `msg_#{ShortHash.of(id)}`, so the same input must always produce the same
  # token across processes and languages. The output is two unsigned 32-bit
  # lanes rendered in base 36 and concatenated, matching pi byte for byte.
  #
  #   Truffle::ShortHash.of("call_abc123") # => "sb0y391xa16ki"
  #
  # Faithfulness rests on two JavaScript details. The loop walks UTF-16 code
  # units the way `charCodeAt` does, so a non-BMP character (an emoji, say)
  # contributes its two surrogate halves, not one code point. And every
  # arithmetic step is 32-bit: `Math.imul` and the shifts and xors all wrap at
  # 32 bits, which we reproduce by masking after each multiply and shifting the
  # already-unsigned lanes.
  module ShortHash
    module_function

    MASK = 0xffffffff

    def of(str)
      units = str.to_s.encode(Encoding::UTF_16BE).unpack("n*")

      h1 = 0xdeadbeef
      h2 = 0x41c6ce57
      units.each do |ch|
        h1 = imul(h1 ^ ch, 2_654_435_761)
        h2 = imul(h2 ^ ch, 1_597_334_677)
      end

      h1 = imul(h1 ^ (h1 >> 16), 2_246_822_507) ^ imul(h2 ^ (h2 >> 13), 3_266_489_909)
      h1 &= MASK
      h2 = imul(h2 ^ (h2 >> 16), 2_246_822_507) ^ imul(h1 ^ (h1 >> 13), 3_266_489_909)
      h2 &= MASK

      h2.to_s(36) + h1.to_s(36)
    end

    # 32-bit integer multiply with wraparound, matching JavaScript `Math.imul`.
    # Both lanes stay in the unsigned 32-bit range, so masking the product is
    # enough to reproduce the same bit pattern JS carries forward.
    def imul(lhs, rhs)
      ((lhs & MASK) * (rhs & MASK)) & MASK
    end
  end
end
