# frozen_string_literal: true

module Truffle
  # JSON text helpers, the port of pi's coding-agent/src/utils/json.ts.
  module Json
    # A full JSON string literal: a quote, then any escaped character or any
    # character that is neither a quote nor a backslash, then a closing quote.
    # Matching a whole literal first is what keeps a "//" or a ",]" inside a string
    # from being treated as a comment or a trailing comma.
    STRING = /"(?:\\.|[^"\\])*"/

    # A string literal or a // line comment (to end of line).
    STRING_OR_LINE_COMMENT = %r{#{STRING}|//[^\n]*}

    # A string literal or a trailing comma: a comma followed by optional whitespace
    # and a closing } or ]. The closer is captured so it can be kept while the comma
    # is dropped.
    STRING_OR_TRAILING_COMMA = /#{STRING}|,(\s*[}\]])/

    module_function

    # Strip // line comments and trailing commas from JSON, leaving string literals
    # untouched, so JSONC (a config file with comments and trailing commas) can be
    # handed to a strict parser. Two passes, matching pi's json.ts: the first drops
    # comments, the second drops trailing commas. In each pass a string literal is
    # matched as a whole and returned unchanged, so its contents are never mistaken
    # for a comment or a trailing comma.
    def strip_comments(input)
      without_comments = input.gsub(STRING_OR_LINE_COMMENT) do |match|
        match.start_with?('"') ? match : ""
      end

      without_comments.gsub(STRING_OR_TRAILING_COMMA) do |match|
        Regexp.last_match(1) || match
      end
    end
  end
end
