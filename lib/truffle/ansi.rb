# frozen_string_literal: true

# The OSC/CSI regex and the strip logic below are derived from ansi-regex and
# strip-ansi (https://github.com/chalk/ansi-regex, https://github.com/chalk/strip-ansi),
# MIT License, Copyright (c) Sindre Sorhus <sindresorhus@gmail.com>, the same
# code pi vendors in coding-agent/src/utils/ansi.ts.

module Truffle
  # Removes ANSI escape sequences from a string. pi cleans captured terminal
  # output through stripAnsi before the model or the UI sees it, so color codes
  # and cursor moves do not leak into the transcript. This is the provider-agnostic
  # port of that stripAnsi; the surrounding bash-output pipeline (binary-output
  # sanitize, carriage-return removal) is wired separately.
  module Ansi
    # A string terminator: BEL, ESC \, or the 8-bit ST (0x9C).
    ST = "(?:\\u0007|\\u001B\\u005C|\\u009C)"

    # An OSC sequence: ESC ] up to the first terminator, non-greedy so it stops at
    # the earliest ST rather than swallowing following sequences.
    OSC = "(?:\\u001B\\][\\s\\S]*?#{ST})".freeze

    # A CSI or related sequence: a 7-bit ESC or 8-bit C1 introducer, optional
    # intermediates, optional numeric parameters (";" and ":" separators), then a
    # final byte.
    CSI = "[\\u001B\\u009B][\\[\\]()#;?]*(?:\\d{1,4}(?:[;:]\\d{0,4})*)?[\\dA-PR-TZcf-nq-uy=><~]"

    REGEX = Regexp.new("#{OSC}|#{CSI}").freeze

    module_function

    def strip(value)
      raise TypeError, "expected a String, got #{value.class}" unless value.is_a?(String)

      # An ANSI sequence needs a 7-bit ESC or an 8-bit CSI introducer, so a string
      # without either cannot contain one. Returning it as-is skips the scan and
      # keeps the original object.
      return value unless value.include?("\u001b") || value.include?("\u009b")

      value.gsub(REGEX, "")
    end
  end
end
