# frozen_string_literal: true

require_relative "path"
require_relative "truncate"
require_relative "gitignore"

module Truffle
  module Tools
    # The find engine, a native port of find.ts's execute path. Nested so its
    # helpers do not collide with the other tools' flat helpers, the way Truncate,
    # Path, Bash, and Edit are nested.
    module Find
      DEFAULT_LIMIT = 1000

      # Directory names pi's default ignore globs ("**/node_modules/**" and
      # "**/.git/**") prune. A match is dropped when one of these appears as an
      # ancestor segment, matching the "/**" tail that requires something beneath.
      EXCLUDED_SEGMENTS = %w[.git node_modules].freeze

      module_function

      def run(pattern:, path:, limit:, cwd:)
        root = Path.resolve(path.nil? || path.empty? ? "." : path, cwd)
        raise "Path not found: #{root}" unless File.exist?(root)

        effective_limit = [1, limit.nil? ? DEFAULT_LIMIT : limit.to_i].max
        matches = search(pattern, root)
        return "No files found matching pattern" if matches.empty?

        limited = matches.first(effective_limit)
        result_limit_reached = limited.length >= effective_limit
        render(limited, effective_limit, result_limit_reached)
      end

      # Match the pattern against the tree under root and return posix-relative
      # paths with .git and node_modules pruned and .gitignore'd paths removed.
      # Dir.glob already yields paths relative to base and sorted, so the output
      # is stable across runs. The exclusion is a superset: a result is dropped
      # when it is a hardcoded-excluded dir (the floor pi's glob branch always
      # prunes) OR matched by the per-directory .gitignore stack (what pi gets
      # from fd's ignore crate). Both are honored, mirroring fd's actual output.
      def search(pattern, root)
        effective = normalize_pattern(pattern)
        flags = File::FNM_EXTGLOB | File::FNM_DOTMATCH
        matcher = Gitignore.matcher(root)
        Dir.glob(effective, base: root, flags: flags).reject do |rel|
          excluded?(rel) || matcher.ignored?(rel, File.directory?(File.join(root, rel)))
        end
      end

      # pi prepends "**/" to a bare pattern so a basename like "*.ts" matches at
      # any depth (fd matches the basename; Dir.glob does not recurse without the
      # "**/" operator). A pattern that is already rooted ("/..."), already
      # recursive ("**/..."), or the bare "**" is left untouched.
      def normalize_pattern(pattern)
        return pattern if pattern.start_with?("/", "**/") || pattern == "**"

        "**/#{pattern}"
      end

      def excluded?(relpath)
        segments = relpath.split("/")
        # Only an ancestor segment prunes a match; a final segment named like an
        # excluded dir is the entry itself and pi's "/**" tail does not match it.
        segments[0...-1].any? { |seg| EXCLUDED_SEGMENTS.include?(seg) }
      end

      # Join the matches, byte-truncate at the shared 50KB ceiling (line count is
      # already bounded by the result limit, so only bytes can truncate here), and
      # append pi's bracketed notices when a ceiling was hit.
      def render(paths, effective_limit, result_limit_reached)
        raw = paths.join("\n")
        truncation = Truncate.head(raw, max_lines: Float::INFINITY)
        output = truncation.content
        notices = []
        if result_limit_reached
          notices << "#{effective_limit} results limit reached. " \
                     "Use limit=#{effective_limit * 2} for more, or refine pattern"
        end
        if truncation.truncated
          notices << "#{Truncate.format_size(Truncate::DEFAULT_MAX_BYTES)} limit reached"
        end
        output += "\n\n[#{notices.join(". ")}]" unless notices.empty?
        output
      end
    end

    FIND_DESCRIPTION =
      "Search for files by glob pattern. Returns matching file paths relative " \
      "to the search directory. Excludes .git, node_modules, and paths matched " \
      "by .gitignore. Output is truncated to #{Find::DEFAULT_LIMIT} results or " \
      "#{Truncate::DEFAULT_MAX_BYTES / 1024}KB (whichever is hit first).".freeze

    # Build pi's `find` tool, bound to a working directory. The model passes a
    # glob pattern, an optional search directory, and an optional result limit;
    # the matching paths are returned relative to the search directory, one per
    # line, posix-separated. pi's default implementation shells out to the `fd`
    # binary (auto-downloaded) so it can honor .gitignore; that pulls an external
    # Rust tool, which breaks the zero-dependency and offline constraints, so this
    # port matches against the filesystem natively with Dir.glob and evaluates
    # the .gitignore stack itself (see Gitignore). .git and node_modules are
    # always excluded, hidden files are included, and per-directory .gitignore
    # rules are honored. pi's TUI call and result rendering is out of scope.
    def self.find(cwd: Dir.pwd)
      Tool.define("find", FIND_DESCRIPTION) do
        param :pattern, :string,
              "Glob pattern to match files, e.g. '*.ts', '**/*.json', or 'src/**/*.spec.ts'",
              required: true
        param :path, :string, "Directory to search in (default: current directory)", required: false
        param :limit, :number, "Maximum number of results (default: 1000)", required: false
        run do |pattern:, path: nil, limit: nil|
          Find.run(pattern: pattern, path: path, limit: limit, cwd: cwd)
        end
      end
    end
  end
end
