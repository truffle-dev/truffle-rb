# frozen_string_literal: true

require "pathname"

module Truffle
  # General path helpers ported from pi's coding-agent utils/paths.ts: classify a
  # value as a local path or a remote package source, canonicalize a path through
  # symlinks, and render a path relative to a working directory for display.
  #
  # The tool-input resolver (unicode-space folding, a leading "@" strip, literal
  # "~user" handling) is a separate concern and lives in Truffle::Tools::Path.
  # These are the provider-agnostic classification-and-display helpers the
  # session, package, and CLI layers reach for. Resolution here uses
  # File.expand_path, Ruby's equivalent of node's path.resolve, which also expands
  # a leading "~" the way pi's normalizePath does.
  module Paths
    # Prefixes pi treats as a non-local source: an npm package, a git or GitHub
    # source, or a remote URL. Everything else (a bare name, a relative or
    # absolute path, a file: URL) is local. file: is intentionally absent because
    # pi resolves a file: URL as a local path.
    REMOTE_SOURCE_PREFIXES = %w[npm: git: github: http: https: ssh:].freeze

    module_function

    # Whether value names a local path rather than a remote package source. Port
    # of pi's isLocalPath: only the known remote prefixes are non-local, so a bare
    # name, a relative path, or a file: URL is local. The value is trimmed first,
    # matching pi.
    def local_path?(value)
      trimmed = value.strip
      REMOTE_SOURCE_PREFIXES.none? { |prefix| trimmed.start_with?(prefix) }
    end

    # The canonical path with every symlink resolved, or the input unchanged when
    # it cannot be resolved (a path that does not exist yet, for example). Port of
    # pi's canonicalizePath, which never raises so a caller can canonicalize a path
    # it is about to create. File.realpath raises on a missing path; the rescue is
    # the fallback pi's try/catch provides.
    def canonicalize(path)
      File.realpath(path)
    rescue SystemCallError
      path
    end

    # The path relative to cwd when it sits inside cwd, or nil when it escapes.
    # cwd itself renders as ".". Both paths are resolved to absolute first, so the
    # result does not depend on the process working directory. Port of pi's
    # getCwdRelativePath. A relative path of ".." or one beginning with "../"
    # points outside cwd and returns nil.
    def cwd_relative_path(file_path, cwd)
      resolved_cwd = File.expand_path(cwd)
      resolved_path = File.expand_path(file_path, resolved_cwd)
      relative = Pathname.new(resolved_path).relative_path_from(resolved_cwd).to_s

      return "." if relative == "."
      return nil if relative == ".." || relative.start_with?("../")

      relative
    end

    # A path formatted for display: relative to cwd when it sits inside, otherwise
    # the absolute path, always with forward slashes. Port of pi's
    # formatPathRelativeToCwdOrAbsolute. On a POSIX host the separator is already
    # "/", so the final swap is a no-op kept for faithfulness.
    def format_relative_to_cwd_or_absolute(file_path, cwd)
      absolute = File.expand_path(file_path, File.expand_path(cwd))
      (cwd_relative_path(absolute, cwd) || absolute).tr(File::SEPARATOR, "/")
    end
  end
end
