# frozen_string_literal: true

require "json"

module Truffle
  # Parses incomplete JSON produced mid-stream, so a model's in-flight tool-call
  # arguments become a usable object before the closing token arrives.
  #
  # `parse` is a from-scratch port of the partial-json package (0.1.7): a
  # recursive-descent parser that returns as much structure as it can from a
  # truncated document, gated by the `Allow` bitmask. `parse_streaming` ports
  # pi's parseStreamingJson from ai/src/utils/json-parse.ts, layering the
  # complete-document repair path (JsonRepair) over the partial parser and
  # always returning an object.
  #
  # pi reaches for the partial-json npm package here; we hand-roll it to keep
  # the zero-runtime-dependency invariant. The partial parser co-locates with
  # parse_streaming because the streaming entry point orchestrates it; pi keeps
  # parseStreamingJson next to the repair helpers instead.
  module PartialJson
    # Bitmask flags: which value types may be returned while still incomplete.
    STR = 0b000000001
    NUM = 0b000000010
    ARR = 0b000000100
    OBJ = 0b000001000
    NULL = 0b000010000
    BOOL = 0b000100000
    NAN = 0b001000000
    INFINITY = 0b010000000
    NEG_INFINITY = 0b100000000
    INF = INFINITY | NEG_INFINITY
    SPECIAL = NULL | BOOL | INF | NAN
    ATOM = STR | NUM | SPECIAL
    COLLECTION = ARR | OBJ
    ALL = ATOM | COLLECTION

    # Raised when the document is incomplete relative to the allowed types.
    class PartialError < StandardError; end

    # Raised when the document is not valid JSON at all.
    class MalformedError < StandardError; end

    module_function

    # Ports parseStreamingJson: best-effort, always returns an object.
    def parse_streaming(partial)
      return {} if partial.nil? || partial.strip.empty?

      begin
        JsonRepair.parse(partial)
      rescue StandardError
        begin
          parse(partial) || {}
        rescue StandardError
          begin
            parse(JsonRepair.repair(partial)) || {}
          rescue StandardError
            {}
          end
        end
      end
    end

    # Ports parseJSON: parse a complete or partial document.
    def parse(json_string, allow: ALL)
      raise MalformedError, "#{json_string} is empty" if json_string.strip.empty?

      Parser.new(json_string.strip, allow).parse
    end

    # Recursive-descent parser over an immutable source string with a cursor.
    # A class holds the cursor that pi threads through closures.
    class Parser
      def initialize(json, allow)
        @json = json
        @length = json.length
        @allow = allow
        @index = 0
      end

      # The literals recognized by parse_keyword, each paired with its Ruby value
      # and the Allow flag that admits a partial (prefix) match.
      KEYWORDS = [
        ["null", nil, NULL],
        ["true", true, BOOL],
        ["false", false, BOOL],
        ["Infinity", Float::INFINITY, INFINITY],
        ["-Infinity", -Float::INFINITY, NEG_INFINITY],
        ["NaN", Float::NAN, NAN]
      ].freeze

      def parse
        parse_any
      end

      private

      def parse_any
        skip_blank
        mark_partial("Unexpected end of input") if @index >= @length

        char = @json[@index]
        return parse_str if char == '"'
        return parse_obj if char == "{"
        return parse_arr if char == "["

        matched = parse_keyword
        return matched.first if matched

        parse_num
      end

      # The null/true/false/Infinity/-Infinity/NaN literals, complete or, when
      # the matching Allow flag is set and the remaining input is a prefix, partial.
      def parse_keyword
        KEYWORDS.each do |word, value, flag|
          next unless keyword_match?(word, flag)

          @index += word.length
          return [value]
        end
        nil
      end

      def keyword_match?(word, flag)
        return true if slice(@index, word.length) == word

        remaining = @length - @index
        return false unless flag.anybits?(@allow) && remaining < word.length

        # -Infinity also requires at least its leading "-" to be present.
        return false if word == "-Infinity" && remaining <= 1

        word.start_with?(slice(@index))
      end

      def parse_str
        start = @index
        escape = false
        @index += 1
        while @index < @length && (@json[@index] != '"' || (escape && @json[@index - 1] == "\\"))
          escape = @json[@index] == "\\" ? !escape : false
          @index += 1
        end

        return closed_str(start, escape) if @json[@index] == '"'
        return partial_str(start, escape) if STR.anybits?(@allow)

        mark_partial("Unterminated string literal")
      end

      def closed_str(start, escape)
        @index += 1
        json_parse(slice(start, (@index - (escape ? 1 : 0)) - start))
      end

      def partial_str(start, escape)
        json_parse("#{slice(start, (@index - (escape ? 1 : 0)) - start)}\"")
      rescue MalformedError
        last_backslash = @json.rindex("\\") || 0
        json_parse("#{slice(start, last_backslash - start)}\"")
      end

      def parse_obj
        @index += 1
        skip_blank
        obj = {}
        begin
          until @json[@index] == "}"
            skip_blank
            return obj if @index >= @length && OBJ.anybits?(@allow)

            key = parse_str
            skip_blank
            @index += 1 # skip the colon without checking it, as pi does
            begin
              obj[key] = parse_any
            rescue PartialError, MalformedError
              return obj if OBJ.anybits?(@allow)

              raise
            end
            skip_blank
            @index += 1 if @json[@index] == ","
          end
        rescue PartialError, MalformedError
          return obj if OBJ.anybits?(@allow)

          mark_partial("Expected '}' at end of object")
        end
        @index += 1
        obj
      end

      def parse_arr
        @index += 1
        arr = []
        begin
          until @json[@index] == "]"
            arr << parse_any
            skip_blank
            @index += 1 if @json[@index] == ","
          end
        rescue PartialError, MalformedError
          return arr if ARR.anybits?(@allow)

          mark_partial("Expected ']' at end of array")
        end
        @index += 1
        arr
      end

      def parse_num
        return parse_whole_num if @index.zero?

        start = @index
        @index += 1 if @json[@index] == "-"
        @index += 1 while @json[@index] && !",]}".include?(@json[@index])
        mark_partial("Unterminated number literal") if @index == @length && NUM.nobits?(@allow)
        num_slice(start)
      end

      def parse_whole_num
        raise MalformedError, "Not sure what '-' is" if @json == "-"

        json_parse(@json)
      rescue MalformedError
        raise unless NUM.anybits?(@allow)

        retry_num_without_exponent(0) { raise }
      end

      def num_slice(start)
        json_parse(slice(start, @index - start))
      rescue MalformedError
        mark_partial("Not sure what '-' is") if slice(start, @index - start) == "-"
        retry_num_without_exponent(start) { raise MalformedError, "invalid number" }
      end

      # After a trailing exponent fails to parse, retry with the "e" and
      # everything after it dropped; if that also fails, run the fallback block.
      def retry_num_without_exponent(start)
        exponent = @json.rindex("e") || -1
        json_parse(js_substring(start, exponent))
      rescue MalformedError
        yield
      end

      def skip_blank
        @index += 1 while @index < @length && " \n\r\t".include?(@json[@index])
      end

      def mark_partial(msg)
        raise PartialError, "#{msg} at position #{@index}"
      end

      # JSON.parse that reports failure as MalformedError, matching how pi wraps
      # the built-in parser's SyntaxError.
      def json_parse(text)
        JSON.parse(text)
      rescue JSON::ParserError => e
        raise MalformedError, e.message
      end

      # str[start, len] but never nil, so callers can concatenate freely.
      def slice(start, len = nil)
        (len ? @json[start, len] : @json[start..]) || ""
      end

      # JavaScript String#substring(start, end): clamps, and swaps the bounds
      # when start is greater than end.
      def js_substring(start_i, end_i)
        start_i = start_i.clamp(0, @length)
        end_i = end_i.clamp(0, @length)
        start_i, end_i = end_i, start_i if start_i > end_i
        @json[start_i...end_i] || ""
      end
    end
  end
end
