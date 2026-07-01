# frozen_string_literal: true

require "json"

module Truffle
  # Repairs malformed JSON string literals so a model's tool-call arguments
  # parse instead of crashing. A faithful port of the dependency-free half of
  # pi's ai/src/utils/json-parse.ts: repairJson and parseJsonWithRepair.
  #
  # Two repairs are applied, and only inside string literals so JSON structure
  # is never touched:
  # - a raw control character (U+0000-U+001F) is replaced with its escape
  # - a backslash before an invalid escape is doubled so it reads as a literal
  #   backslash rather than starting an escape the parser rejects
  #
  # pi's streaming parseStreamingJson, which completes truncated JSON, depends
  # on the partial-json package and is a separate slice.
  module JsonRepair
    # The characters JSON allows immediately after a backslash.
    VALID_ESCAPES = ['"', "\\", "/", "b", "f", "n", "r", "t", "u"].freeze

    # Control characters that have a short escape form; the rest use \uXXXX.
    CONTROL_ESCAPES = { "\b" => "\\b", "\f" => "\\f", "\n" => "\\n",
                        "\r" => "\\r", "\t" => "\\t" }.freeze

    HEX_DIGIT = /\A[0-9a-fA-F]\z/

    module_function

    # The input with malformed string literals repaired. A string that needs no
    # repair is returned with the same content (a new String is still built).
    def repair(json)
      chars = json.chars
      repaired = +""
      in_string = false
      index = 0

      while index < chars.length
        char = chars[index]

        unless in_string
          repaired << char
          in_string = true if char == '"'
          index += 1
          next
        end

        if char == '"'
          repaired << char
          in_string = false
          index += 1
          next
        end

        if char == "\\"
          index += repair_escape(chars, index, repaired)
          next
        end

        repaired << (control_character?(char) ? escape_control(char) : char)
        index += 1
      end

      repaired
    end

    # Parse JSON, repairing malformed string literals only if the first parse
    # fails and the repair actually changed the input. When repair changes
    # nothing, the original error is raised so a genuinely broken document still
    # surfaces its parse error.
    def parse(json)
      JSON.parse(json)
    rescue JSON::ParserError => e
      repaired = repair(json)
      raise e if repaired == json

      JSON.parse(repaired)
    end

    # Repair a backslash escape starting at chars[index]. Appends the repaired
    # text to `repaired` and returns how many input characters it consumed.
    def repair_escape(chars, index, repaired)
      next_char = chars[index + 1]

      if next_char.nil?
        repaired << "\\\\"
        return 1
      end

      if next_char == "u" && hex4?(chars, index + 2)
        repaired << "\\u" << chars[(index + 2), 4].join
        return 6
      end

      if VALID_ESCAPES.include?(next_char)
        repaired << "\\" << next_char
        return 2
      end

      repaired << "\\\\"
      1
    end
    private_class_method :repair_escape

    # True when chars[start, 4] is exactly four hex digits.
    def hex4?(chars, start)
      slice = chars[start, 4]
      slice&.length == 4 && slice.all? { |c| c.match?(HEX_DIGIT) }
    end
    private_class_method :hex4?

    def control_character?(char)
      char.ord <= 0x1F
    end
    private_class_method :control_character?

    def escape_control(char)
      CONTROL_ESCAPES[char] || format("\\u%04x", char.ord)
    end
    private_class_method :escape_control
  end
end
