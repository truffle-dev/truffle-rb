# frozen_string_literal: true

module Truffle
  # A gitignore-style path matcher, ported from the `ignore` npm package that pi
  # layers over its skills directory walk (skills.ts builds one with `ignore()`).
  # A zero-dependency port has to hand-roll it: each pattern is compiled to a
  # Ruby Regexp following the package's gitignore-to-regex pipeline, and a path is
  # tested against the rules in order with last-match-wins negation.
  #
  # Usage:
  #
  #   ig = Truffle::Ignore.new
  #   ig.add(File.read(".gitignore"))   # a String (split on newlines) or an Array
  #   ig.ignores?("build/app.log")      # => true
  #
  # Matching mirrors git: a leading or embedded "/" anchors a pattern to the root,
  # an unanchored pattern matches at any depth, a trailing "/" matches directories
  # only, "*" matches within a path segment, "**" spans segments, "!" re-includes,
  # "#" lines are comments, and blank lines are skipped. A path is also ignored
  # when any ancestor directory is ignored, since git cannot re-include a file
  # under an excluded directory. Like the package's default, matching is case
  # insensitive.
  class Ignore
    # One compiled pattern: the Regexp it tests against and whether it negates
    # (a leading "!" re-includes paths an earlier rule excluded).
    Rule = Struct.new(:regex, :negative, keyword_init: true)

    def initialize
      @rules = []
    end

    # Add patterns. Accepts a String (split on CR/LF into lines) or an Array of
    # individual pattern strings. Blank lines, comments, and patterns with an
    # unescaped trailing backslash are dropped. Returns self so calls can chain.
    def add(patterns)
      lines = patterns.is_a?(Array) ? patterns : patterns.split(/\r?\n/)
      lines.each do |line|
        next if line.nil?

        rule = compile(line)
        @rules << rule if rule
      end
      self
    end

    # Whether a posix relative path (e.g. "src/build/app.log", or a directory as
    # "src/build/") is ignored by the accumulated rules.
    def ignores?(path)
      return false if path.nil? || path.empty?

      path_ignored?(path)
    end

    private

    # Mirror the package's _t: a path is ignored if an ancestor directory is
    # ignored (a child of an excluded directory cannot be re-included), otherwise
    # the path is matched directly.
    def path_ignored?(path)
      slices = path.split("/").reject(&:empty?)
      slices.pop
      return true if slices.any? && path_ignored?("#{slices.join("/")}/")

      rules_match?(path)
    end

    # Run the rules in order. A positive rule that matches marks the path ignored;
    # a later negative rule that matches re-includes it. Negative rules are only
    # consulted once something has already ignored the path (checkUnignored is
    # false here), matching the package's skip table.
    def rules_match?(path)
      ignored = false
      unignored = false
      @rules.each do |rule|
        negative = rule.negative
        next if (unignored == negative && ignored != unignored) ||
                (negative && !ignored && !unignored)
        next unless rule.regex.match?(path)

        ignored = !negative
        unignored = negative
      end
      ignored
    end

    # Compile one gitignore line into a Rule, or nil when the line is not a
    # pattern (blank, comment, or invalid trailing backslash).
    def compile(line)
      return nil unless pattern?(line)

      negative = line.start_with?("!")
      body = negative ? line[1..] : line
      # A literal leading "!" or "#" is written escaped; unescape it now.
      body = body.sub(/\A\\!/, "!").sub(/\A\\#/, "#")
      source = trailing_wildcard(regex_prefix(body))
      Rule.new(regex: Regexp.new(source, Regexp::IGNORECASE), negative: negative)
    end

    # A line is a pattern unless it is empty, whitespace-only, a comment, or ends
    # with a lone unescaped backslash.
    def pattern?(line)
      return false if line.nil? || line.empty?
      return false if line.match?(/\A\s+\z/)
      return false if line.match?(/(?:[^\\]|\A)\\\z/)
      return false if line.start_with?("#")

      true
    end

    # The gitignore-to-regex pipeline, applied in order. Each step mirrors a
    # replacer in the `ignore` package; `body` is the original pattern, consulted
    # by the anchoring step to decide root-anchored vs match-at-any-depth.
    def regex_prefix(body)
      str = body.dup
      str = str.sub(/\A\uFEFF/, "") # strip BOM
      str = strip_trailing_spaces(str) # unquoted trailing spaces
      str = collapse_backslash_space(str) # "\ " -> " "
      str = str.gsub(/[\\$.|*+(){^]/) { "\\#{::Regexp.last_match(0)}" } # escape metacharacters
      str = str.gsub(/(?!\\)\?/) { "[^/]" } # "?" -> one non-slash
      str = str.sub(%r{\A/}, "^") # leading slash anchors
      str = str.gsub("/", "\\/") # escape remaining slashes
      str = str.sub(%r{\A\^*\\\*\\\*\\/}, "^(?:.*\\/)?") # leading "**/"
      str = anchor(str, body) # root vs any-depth
      str = expand_double_stars(str) # "/**/" and trailing "/**"
      # interior "*" -> one path segment
      str = str.gsub(/(\A|[^\\]+)(?:\\\*)+(?=.+)/) { "#{::Regexp.last_match(1)}[^/]*" }
      str = str.gsub(/\\\\\\(?=[$.|*+(){^])/) { "\\" } # revert over-escaped metachar
      str = str.gsub("\\\\") { "\\" } # "\\" -> "\"
      str = replace_ranges(str) # "[a-z]" character classes
      ending(str) # file-or-dir vs dir-only tail
    end

    # Trailing spaces are dropped unless the last one is backslash-quoted.
    def strip_trailing_spaces(str)
      str.sub(/((?:\\\\)*?)(\\?\s+)\z/) do
        head = ::Regexp.last_match(1)
        ::Regexp.last_match(2).start_with?("\\") ? "#{head} " : head
      end
    end

    # Collapse a run of backslashes before whitespace: keep the escaped pairs and
    # turn the escaping backslash plus the space into a single literal space.
    def collapse_backslash_space(str)
      str.gsub(/(\\+?)\s/) do
        run = ::Regexp.last_match(1)
        len = run.length
        "#{run[0, len - (len % 2)]} "
      end
    end

    # The starting replacer: if the pattern is not already root-anchored, anchor
    # it to the root when it has a slash at the beginning or middle, otherwise let
    # it match at any depth below the ignore file.
    def anchor(str, body)
      return str if str.start_with?("^") || str.empty?

      prefix = body.match?(%r{/(?!\z)}) ? "^" : "(?:^|\\/)"
      "#{prefix}#{str}"
    end

    # Expand globstars: an interior "/**/" matches zero or more directories, a
    # trailing "/**" matches everything beneath.
    def expand_double_stars(str)
      len = str.length
      str.gsub(%r{\\/\\\*\\\*(?=\\/|\z)}) do
        ::Regexp.last_match.end(0) < len ? "(?:\\/[^\\/]+)*" : "\\/.+"
      end
    end

    # Sanitize character-class ranges so an out-of-order range (valid for git but
    # fatal for a Ruby Regexp) is dropped rather than raising.
    def replace_ranges(str)
      str.gsub(%r{(\\)?\[([^\]/]*?)(\\*)(\z|\])}) do
        lead = ::Regexp.last_match(1)
        range = ::Regexp.last_match(2)
        end_esc = ::Regexp.last_match(3)
        close = ::Regexp.last_match(4)
        if lead == "\\"
          "\\[#{range}#{clean_range_backslash(end_esc)}#{close}"
        elsif close == "]" && end_esc.length.even?
          "[#{sanitize_range(range)}#{end_esc}]"
        else
          "[]"
        end
      end
    end

    def sanitize_range(range)
      range.gsub(/([0-z])-([0-z])/) do
        from = ::Regexp.last_match(1)
        to = ::Regexp.last_match(2)
        from.ord <= to.ord ? "#{from}-#{to}" : ""
      end
    end

    def clean_range_backslash(slashes)
      len = slashes.length
      slashes[0, len - (len % 2)]
    end

    # The ending replacer: a trailing slash makes the pattern match directories
    # only; otherwise the last character may be a file or a directory.
    def ending(str)
      str.sub(/[^*]\z/) { |char| char == "/" ? "#{char}$" : "#{char}(?=$|\\/$)" }
    end

    # A trailing "*" matches a non-empty single segment when anchored to a
    # directory ("abc/*"), or any segment otherwise ("a*").
    def trailing_wildcard(prefix)
      prefix.sub(%r{(\A|\\/)?\\\*\z}) do
        lead = ::Regexp.last_match(1)
        head = lead == "\\/" ? "#{lead}[^/]+" : "[^/]*"
        "#{head}(?=$|\\/$)"
      end
    end
  end
end
