# frozen_string_literal: true

require "json"
require_relative "path"

module Truffle
  module Tools
    EDIT_DESCRIPTION =
      "Edit a single file using exact text replacement. Every edits[].oldText " \
      "must match a unique, non-overlapping region of the original file. If two " \
      "changes affect the same block or nearby lines, merge them into one edit " \
      "instead of emitting overlapping edits. Do not include large unchanged " \
      "regions just to connect distant changes."

    EDITS_DESCRIPTION =
      "One or more targeted replacements. Each edit is matched against the " \
      "original file, not incrementally. Do not include overlapping or nested " \
      "edits. If two changes touch the same block or nearby lines, merge them " \
      "into one edit instead."

    EDIT_ITEM_SCHEMA = {
      type: "object",
      properties: {
        "oldText" => {
          type: "string",
          description: "Exact text for one targeted replacement. It must be " \
                       "unique in the original file and must not overlap with " \
                       "any other edits[].oldText in the same call."
        },
        "newText" => {
          type: "string",
          description: "Replacement text for this targeted edit."
        }
      },
      required: %w[oldText newText],
      additionalProperties: false
    }.freeze

    # Build pi's `edit` tool, bound to a working directory. The model passes a
    # path and a list of {oldText, newText} replacements; each oldText must match
    # the original file exactly (or under pi's fuzzy normalization) and uniquely,
    # the matches must not overlap, and at least one byte must change. On success
    # the file is rewritten and a count of replaced blocks is returned; any
    # violation raises with pi's message, which the agent loop reports to the
    # model. pi's diff and unified-patch rendering feeds only the TUI and pulls in
    # the `diff` package, so it is out of scope here.
    def self.edit(cwd: Dir.pwd)
      Tool.define("edit", EDIT_DESCRIPTION, execution_mode: :sequential) do
        param :path, :string, "Path to the file to edit (relative or absolute)", required: true
        param :edits, :array, EDITS_DESCRIPTION, required: true, items: EDIT_ITEM_SCHEMA
        run do |path:, edits: nil, **legacy|
          Edit.run(path: path, edits: edits, legacy: legacy, cwd: cwd)
        end
      end
    end

    # The edit engine, a port of edit.ts's execute path plus the matching core in
    # edit-diff.ts. Nested so its many private helpers do not collide with the
    # other tools' flat helpers, the way Truncate, Path, and Bash are nested.
    module Edit
      # Smart quotes, Unicode dashes, and special spaces that fuzzy matching folds
      # to their ASCII equivalents, so a paste with curly quotes still matches.
      SMART_SINGLE_QUOTES = /[\u2018\u2019\u201A\u201B]/
      SMART_DOUBLE_QUOTES = /[\u201C\u201D\u201E\u201F]/
      UNICODE_DASHES = /[\u2010\u2011\u2012\u2013\u2014\u2015\u2212]/
      SPECIAL_SPACES = /[\u00A0\u2002-\u200A\u202F\u205F\u3000]/
      BOM = "\uFEFF"

      module_function

      def run(path:, edits:, legacy:, cwd:)
        edits = prepare_edits(edits, legacy)
        unless edits.is_a?(Array) && !edits.empty?
          raise "Edit tool input is invalid. edits must contain at least one replacement."
        end

        absolute = Path.resolve(path, cwd)
        ensure_editable(absolute, path)

        raw = File.read(absolute, encoding: "UTF-8")
        bom, content = strip_bom(raw)
        ending = detect_line_ending(content)
        _base, new_content = apply_edits(normalize_to_lf(content), edits, path)

        File.write(absolute, bom + restore_line_endings(new_content, ending))
        "Successfully replaced #{edits.length} block(s) in #{path}."
      end

      # pi's prepareArguments: some models send `edits` as a JSON string, and an
      # older single-edit shape sends top-level oldText/newText. Parse the string
      # form and fold a legacy pair onto the end of the list.
      def prepare_edits(edits, legacy)
        edits = parse_json_array(edits) if edits.is_a?(String)
        edits = [] unless edits.is_a?(Array)
        old_text = legacy[:oldText]
        new_text = legacy[:newText]
        return edits unless old_text.is_a?(String) && new_text.is_a?(String)

        edits + [{ "oldText" => old_text, "newText" => new_text }]
      end

      def parse_json_array(string)
        parsed = JSON.parse(string)
        parsed.is_a?(Array) ? parsed : string
      rescue JSON::ParserError
        string
      end

      # pi calls fs.access with the default F_OK mode, so it only checks that the
      # file exists and reports the errno code on failure. The only code that
      # check produces in practice is ENOENT.
      def ensure_editable(absolute, path)
        return if File.exist?(absolute)

        raise "Could not edit file: #{path}. Error code: ENOENT."
      end

      # --- matching core (edit-diff.ts) -----------------------------------------

      def apply_edits(normalized, edits, path)
        norm_edits = edits.map do |edit|
          { old: normalize_to_lf(edit["oldText"]), new: normalize_to_lf(edit["newText"]) }
        end
        norm_edits.each_with_index do |edit, i|
          raise empty_old_text_error(path, i, norm_edits.length) if edit[:old].empty?
        end

        used_fuzzy = norm_edits.any? { |edit| fuzzy_find(normalized, edit[:old])[:used_fuzzy] }
        base = used_fuzzy ? normalize_for_fuzzy_match(normalized) : normalized
        matched = match_edits(base, norm_edits, path)
        check_overlaps(matched, path)

        new_content =
          if used_fuzzy
            apply_preserving(normalized, base, matched)
          else
            apply_replacements(base, matched)
          end
        raise no_change_error(path, norm_edits.length) if normalized == new_content

        [normalized, new_content]
      end

      def match_edits(base, norm_edits, path)
        matched = norm_edits.each_with_index.map do |edit, i|
          match = fuzzy_find(base, edit[:old])
          raise not_found_error(path, i, norm_edits.length) unless match[:found]

          occurrences = count_occurrences(base, edit[:old])
          raise duplicate_error(path, i, norm_edits.length, occurrences) if occurrences > 1

          { edit_index: i, match_index: match[:index],
            match_length: match[:match_length], new_text: edit[:new] }
        end
        matched.sort_by { |edit| edit[:match_index] }
      end

      def check_overlaps(matched, path)
        (1...matched.length).each do |i|
          previous = matched[i - 1]
          current = matched[i]
          previous_end = previous[:match_index] + previous[:match_length]
          next unless previous_end > current[:match_index]

          raise overlap_error(path, previous[:edit_index], current[:edit_index])
        end
      end

      def overlap_error(path, previous_index, current_index)
        "edits[#{previous_index}] and edits[#{current_index}] overlap in #{path}. " \
          "Merge them into one edit or target disjoint regions."
      end

      # Exact match first; on a miss, fold both sides through fuzzy normalization
      # and search again. Offsets and lengths are in characters, internally
      # consistent the way pi's are in UTF-16 code units.
      def fuzzy_find(content, old_text)
        exact = content.index(old_text)
        unless exact.nil?
          return { found: true, index: exact, match_length: old_text.length, used_fuzzy: false }
        end

        fuzzy_content = normalize_for_fuzzy_match(content)
        fuzzy_old = normalize_for_fuzzy_match(old_text)
        index = fuzzy_content.index(fuzzy_old)
        return { found: false, index: -1, match_length: 0, used_fuzzy: false } if index.nil?

        { found: true, index: index, match_length: fuzzy_old.length, used_fuzzy: true }
      end

      def count_occurrences(content, old_text)
        haystack = normalize_for_fuzzy_match(content)
        needle = normalize_for_fuzzy_match(old_text)
        # pi uses String.split, which in JS splits on the literal separator. A
        # plain Ruby split(" ") would trigger awk mode (splitting on whitespace
        # runs), so escape the needle into a regexp to keep literal semantics,
        # and pass -1 so a trailing match still counts.
        haystack.split(Regexp.new(Regexp.escape(needle)), -1).length - 1
      end

      # Apply replacements back to front so earlier match offsets stay valid. The
      # offset rebases indices that were computed against a larger string slice.
      def apply_replacements(content, replacements, offset = 0)
        result = content
        replacements.reverse_each do |replacement|
          index = replacement[:match_index] - offset
          tail = index + replacement[:match_length]
          result = result[0...index] + replacement[:new_text] + result[tail..]
        end
        result
      end

      # When a fuzzy match was used, the replacements were matched against the
      # fuzzy-normalized base, which may differ byte for byte from the original.
      # Rewrite only the lines a replacement actually touches from the base, and
      # copy every other line back from the original so unchanged blocks keep
      # their exact bytes. The touched ranges drive preservation, so duplicate
      # normalized lines cannot align to the wrong occurrence.
      def apply_preserving(original, base, replacements)
        original_lines = split_lines_with_endings(original)
        base_lines = line_spans(base)
        if original_lines.length != base_lines.length
          raise "Cannot preserve unchanged lines because the base content has a " \
                "different line count."
        end

        groups = group_replacements(base_lines, replacements)
        stitch(original_lines, base, base_lines, groups)
      end

      def group_replacements(base_lines, replacements)
        groups = []
        replacements.sort_by { |replacement| replacement[:match_index] }.each do |replacement|
          range = replacement_line_range(base_lines, replacement)
          current = groups.last
          if current && range[:start_line] < current[:end_line]
            current[:end_line] = [current[:end_line], range[:end_line]].max
            current[:replacements] << replacement
          else
            groups << { start_line: range[:start_line], end_line: range[:end_line],
                        replacements: [replacement] }
          end
        end
        groups
      end

      def stitch(original_lines, base, base_lines, groups)
        index = 0
        result = +""
        groups.each do |group|
          result << original_lines[index...group[:start_line]].join
          group_start = base_lines[group[:start_line]][:start]
          group_end = base_lines[group[:end_line] - 1][:end]
          slice = base[group_start...group_end]
          result << apply_replacements(slice, group[:replacements], group_start)
          index = group[:end_line]
        end
        result << original_lines[index..].join
        result
      end

      def replacement_line_range(lines, replacement)
        match_start = replacement[:match_index]
        match_end = replacement[:match_index] + replacement[:match_length]

        start_line = lines.index { |line| match_start >= line[:start] && match_start < line[:end] }
        raise "Replacement range is outside the base content." if start_line.nil?

        end_line = start_line
        end_line += 1 while end_line < lines.length && lines[end_line][:end] < match_end
        raise "Replacement range is outside the base content." if end_line >= lines.length

        { start_line: start_line, end_line: end_line + 1 }
      end

      def line_spans(content)
        offset = 0
        split_lines_with_endings(content).map do |line|
          span = { start: offset, end: offset + line.length }
          offset = span[:end]
          span
        end
      end

      # Each line keeps its own trailing newline; a final line without one is kept
      # as is. An empty string yields no lines.
      def split_lines_with_endings(content)
        content.scan(/[^\n]*\n|[^\n]+/)
      end

      # --- normalization (edit-diff.ts) -----------------------------------------

      def normalize_to_lf(text)
        text.gsub("\r\n", "\n").gsub("\r", "\n")
      end

      def restore_line_endings(text, ending)
        ending == "\r\n" ? text.gsub("\n", "\r\n") : text
      end

      def detect_line_ending(content)
        crlf = content.index("\r\n")
        lf = content.index("\n")
        return "\n" if lf.nil? || crlf.nil?

        crlf < lf ? "\r\n" : "\n"
      end

      def strip_bom(content)
        content.start_with?(BOM) ? [BOM, content[1..]] : ["", content]
      end

      def normalize_for_fuzzy_match(text)
        text.unicode_normalize(:nfkc)
            .split("\n", -1).map(&:rstrip).join("\n")
            .gsub(SMART_SINGLE_QUOTES, "'")
            .gsub(SMART_DOUBLE_QUOTES, '"')
            .gsub(UNICODE_DASHES, "-")
            .gsub(SPECIAL_SPACES, " ")
      end

      # --- error messages (edit-diff.ts) ----------------------------------------

      def empty_old_text_error(path, index, total)
        return "oldText must not be empty in #{path}." if total == 1

        "edits[#{index}].oldText must not be empty in #{path}."
      end

      def not_found_error(path, index, total)
        if total == 1
          "Could not find the exact text in #{path}. " \
            "The old text must match exactly including all whitespace and newlines."
        else
          "Could not find edits[#{index}] in #{path}. " \
            "The oldText must match exactly including all whitespace and newlines."
        end
      end

      def duplicate_error(path, index, total, occurrences)
        if total == 1
          "Found #{occurrences} occurrences of the text in #{path}. " \
            "The text must be unique. Please provide more context to make it unique."
        else
          "Found #{occurrences} occurrences of edits[#{index}] in #{path}. " \
            "Each oldText must be unique. Please provide more context to make it unique."
        end
      end

      def no_change_error(path, total)
        if total == 1
          "No changes made to #{path}. The replacement produced identical content. " \
            "This might indicate an issue with special characters or the text not " \
            "existing as expected."
        else
          "No changes made to #{path}. The replacements produced identical content."
        end
      end
    end
  end
end
