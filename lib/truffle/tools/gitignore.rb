# frozen_string_literal: true

module Truffle
  module Tools
    # A gitignore matcher for the find tool. pi gets .gitignore support for free
    # from the `fd` binary (the Rust `ignore` crate); since this port matches the
    # tree natively, the rules are evaluated here instead. The implementation
    # follows gitignore(5): per-directory .gitignore files, last-match-wins with
    # negation, anchored vs floating patterns, directory-only patterns, and the
    # "**" forms. A directory excluded by a rule prunes everything beneath it, so
    # a file cannot be re-included while its parent stays excluded.
    #
    # Not yet covered (faithful follow-ups): the global excludesfile,
    # .git/info/exclude, .ignore/.fdignore files, and nested-repo boundaries.
    module Gitignore
      # segments: the pattern split on "/" (with "**" kept as its own segment);
      # negated: a leading "!" re-include; dir_only: a trailing "/"; anchored: a
      # "/" anywhere but the end, so the pattern is rooted at its .gitignore dir.
      Rule = Struct.new(:segments, :negated, :dir_only, :anchored)

      # Within one path segment there is no "/", so a single-segment fnmatch only
      # needs DOTMATCH: gitignore's "*" matches leading dots, unlike shell glob.
      SEGMENT_FLAGS = File::FNM_DOTMATCH

      module_function

      def matcher(root)
        Matcher.new(root)
      end

      # Parse one .gitignore file's text into rules, in file order.
      def parse(text)
        text.each_line(chomp: true).filter_map { |line| parse_line(line) }
      end

      def parse_line(raw)
        line = strip_trailing_spaces(raw)
        return nil if line.empty? || line.start_with?("#")

        negated = line.start_with?("!")
        line = line[1..] if negated
        line = line[1..] if line.start_with?("\\") # \# or \! is a literal first char
        return nil if line.empty?

        dir_only = line.end_with?("/")
        line = line[0...-1] if dir_only
        return nil if line.empty?

        anchored = line.include?("/")
        line = line[1..] if line.start_with?("/")
        Rule.new(line.split("/"), negated, dir_only, anchored)
      end

      # gitignore ignores trailing spaces unless one is escaped with a backslash.
      def strip_trailing_spaces(line)
        line.sub(/(?<!\\) +\z/, "")
      end

      # Match a pattern's segments against a path's segments, honoring "**":
      # a non-final "**" spans zero or more segments, a final "**" spans one or
      # more (gitignore's trailing "/**" means "everything inside", not the dir).
      def match_segments?(pattern, path)
        return path.empty? if pattern.empty?

        head, *rest = pattern
        return match_double_star(rest, path) if head == "**"
        return false if path.empty? || !File.fnmatch?(head, path[0], SEGMENT_FLAGS)

        match_segments?(rest, path[1..])
      end

      def match_double_star(rest, path)
        return !path.empty? if rest.empty?
        return true if match_segments?(rest, path)

        path.each_index.any? { |i| match_segments?(rest, path[(i + 1)..]) }
      end

      # Evaluates a path against the per-directory .gitignore stack from the git
      # root (or the search root when outside a repo) down to the path's parent.
      class Matcher
        def initialize(root)
          @root = root
          @boundary = git_root(root) || root
          @cache = {}
        end

        # A path is ignored when any ancestor directory is ignored (the prune
        # rule) or the entry itself matches an active rule.
        def ignored?(rel, is_dir)
          abs = File.join(@root, rel)
          ancestors(abs).each { |dir| return true if entry_ignored?(dir, true) }
          entry_ignored?(abs, is_dir)
        end

        private

        def entry_ignored?(abs, is_dir)
          result = false
          layer_dirs(abs).each do |dir|
            sub = abs[(dir.length + 1)..]
            next if sub.nil? || sub.empty?

            path = sub.split("/")
            rules_for(dir).each do |rule|
              next if rule.dir_only && !is_dir

              segments = rule.anchored ? rule.segments : ["**", *rule.segments]
              result = !rule.negated if Gitignore.match_segments?(segments, path)
            end
          end
          result
        end

        # Ancestor directories strictly between the search root and the path,
        # shallowest first, so the prune check tests outer directories before
        # inner ones.
        def ancestors(abs)
          dirs = []
          dir = File.dirname(abs)
          while dir.length > @root.length && dir.start_with?(@root)
            dirs << dir
            dir = File.dirname(dir)
          end
          dirs.reverse
        end

        # .gitignore-owning directories from the boundary down to the path's
        # parent, shallowest first so deeper files override shallower ones.
        def layer_dirs(abs)
          dirs = []
          dir = File.dirname(abs)
          while dir.length >= @boundary.length && dir.start_with?(@boundary)
            dirs << dir
            break if dir == @boundary

            dir = File.dirname(dir)
          end
          dirs.reverse
        end

        def rules_for(dir)
          @cache[dir] ||= begin
            path = File.join(dir, ".gitignore")
            File.file?(path) ? Gitignore.parse(File.read(path, encoding: "UTF-8")) : []
          end
        end

        def git_root(start)
          dir = start
          loop do
            return dir if File.directory?(File.join(dir, ".git"))

            parent = File.dirname(dir)
            return nil if parent == dir

            dir = parent
          end
        end
      end
    end
  end
end
