# frozen_string_literal: true

module Truffle
  module Tools
    # Path resolution for the file tools, a port of pi's resolveToCwd
    # (path-utils.ts) layered over normalizePath/resolvePath (paths.ts). A
    # tool-supplied path is normalized (unicode space variants folded to a plain
    # space, a single leading "@" stripped, a leading "~" or "~/" expanded to the
    # home directory) and then resolved against the tool's working directory,
    # collapsing "." and ".." the way node's path.resolve does. file:// URLs are
    # out of scope, matching the read tool's original resolution.
    module Path
      # The unicode space variants pi folds to a plain space before resolving:
      # no-break space, the en/em quad family, the narrow/medium math spaces, and
      # the ideographic space. gsub is global, matching JS's /g flag.
      UNICODE_SPACES = /[\u00A0\u2000-\u200A\u202F\u205F\u3000]/

      module_function

      # Resolve a tool path against cwd. The path is normalized with unicode-space
      # folding and @-strip (pi's resolveToCwd options); cwd is normalized with
      # tilde expansion only (pi normalizes the base dir with default options).
      def resolve(path, cwd)
        normalized = normalize(path, strip_at: true)
        base = normalize(cwd)
        return File.expand_path(normalized) if absolute?(normalized)

        # A "~user" form survives tilde expansion as a literal token in pi
        # (normalizePath only expands "~" and "~/"). Anchor it with "./" so Ruby's
        # File.expand_path treats it as a relative name instead of looking the user
        # up and raising on an unknown one.
        normalized = "./#{normalized}" if normalized.start_with?("~")
        File.expand_path(normalized, base)
      end

      # pi's normalizePath: fold unicode spaces, optionally strip one leading "@",
      # then expand a leading "~"/"~/" to the home directory.
      def normalize(input, strip_at: false)
        normalized = input.gsub(UNICODE_SPACES, " ")
        normalized = normalized[1..] if strip_at && normalized.start_with?("@")
        expand_tilde(normalized)
      end

      def expand_tilde(path)
        home = Dir.home
        return home if path == "~"
        return File.join(home, path[2..]) if path.start_with?("~/")

        path
      end

      # POSIX isAbsolute: a leading slash. Linux-first, matching the rest of the
      # tool surface.
      def absolute?(path)
        path.start_with?("/")
      end
    end
  end
end
