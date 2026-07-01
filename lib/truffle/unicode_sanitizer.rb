# frozen_string_literal: true

module Truffle
  # Removes lone Unicode surrogate characters from a string so it can be
  # serialized into a provider request body. Unpaired surrogates cause JSON
  # serialization errors at many providers, so provider serializers run text
  # through this before encoding it. A faithful port of pi's
  # packages/ai/src/utils/sanitize-unicode.ts.
  #
  # pi operates on UTF-16 code units and strips unpaired surrogates while
  # preserving surrogate pairs. Ruby strings are UTF-8, where a valid astral
  # character (an emoji, say) is a single codepoint and never appears as a
  # surrogate. A lone or WTF-8/CESU-8 encoded surrogate instead shows up as the
  # invalid three-byte sequence ED A0-BF 80-BF, which is what this removes. Valid
  # text is untouched, including emoji and the adjacent valid range
  # U+D000-U+D7FF (encoded ED 80-9F 80-BF), so the behavior matches pi's intent:
  # drop the surrogates that break serialization, keep everything else.
  module UnicodeSanitizer
    # The WTF-8/CESU-8 byte encoding of a surrogate codepoint (U+D800-U+DFFF):
    # lead byte ED, then a continuation byte in A0-BF, then one in 80-BF. Valid
    # three-byte UTF-8 in the U+D000-U+D7FF range uses ED 80-9F and is not
    # matched. The /n flag pins the pattern to ASCII-8BIT so it matches raw bytes.
    SURROGATE_BYTES = /\xED[\xA0-\xBF][\x80-\xBF]/n

    module_function

    # The text with any lone surrogate byte sequences removed. A string with no
    # surrogates is returned unchanged (same object), so a clean, frozen input
    # stays frozen; otherwise a new UTF-8 string is returned.
    def sanitize_surrogates(text)
      bytes = text.b
      return text unless bytes.match?(SURROGATE_BYTES)

      bytes.gsub!(SURROGATE_BYTES, "")
      bytes.force_encoding(Encoding::UTF_8)
    end
  end
end
