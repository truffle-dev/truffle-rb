# frozen_string_literal: true

require "json"

module Truffle
  # Extension discovery, the Ruby port of the pure filesystem layer in pi's
  # extension loader (packages/coding-agent/src/core/extensions/loader.ts). This
  # is the seam that finds extension *entry points* on disk before anything is
  # loaded or executed. Loading a discovered module (pi imports a TS module; the
  # Ruby host will either `require` a file or take a registration block) is a
  # separate, later concern and lives nowhere in here.
  #
  # The discovery rules carry over from pi exactly:
  #
  # - Direct files in a directory are entry points. pi treats `.ts`/`.js` as
  #   extension files; the Ruby analog is `.rb`, since a Ruby extension is Ruby
  #   code the way a pi extension is TypeScript.
  # - A subdirectory is an entry point if it carries a manifest that declares
  #   extensions, or failing that an `index.rb`. The manifest is the same
  #   `package.json` with a top-level `pi` field that pi reads; JSON parsing is
  #   standard library, so that shape is retained verbatim rather than invented
  #   anew.
  # - Discovery descends exactly one level. A package more complex than a single
  #   file or a lone index must spell its entry points out in the manifest.
  #
  # Every filesystem touch is tolerant: a missing directory yields no entries, a
  # malformed manifest yields no manifest, and a directory that cannot be read
  # yields no entries rather than raising. pi swallows these the same way so a
  # single broken package cannot abort discovery for the rest.
  module Extensions
    module_function

    # True when a bare filename names a Ruby extension file. pi's isExtensionFile
    # accepts `.ts` or `.js`; the faithful Ruby mapping is `.rb`.
    def extension_file?(name)
      name.end_with?(".rb")
    end

    # The `pi` manifest hash read from a package.json, or nil. Ports pi's
    # readPiManifest: parse the JSON, return its `pi` object when present and
    # object-shaped, and treat any read or parse failure as "no manifest" by
    # returning nil. String keys, matching JSON.parse's default.
    def read_manifest(package_json_path)
      content = File.read(package_json_path)
      pkg = JSON.parse(content)
      pi = pkg["pi"]
      pi.is_a?(Hash) ? pi : nil
    rescue StandardError
      nil
    end

    # The resolved extension entry paths for a single directory, or nil when the
    # directory advertises no entry point. Ports resolveExtensionEntries: a
    # manifest with a non-empty `extensions` list wins, resolving each declared
    # path against the directory and keeping only those that exist; if that
    # yields nothing, fall back to an `index.rb`. Absolute paths throughout, to
    # match pi handing back resolved paths.
    def resolve_entries(dir)
      package_json_path = File.join(dir, "package.json")
      if File.exist?(package_json_path)
        manifest = read_manifest(package_json_path)
        declared = manifest && manifest["extensions"]
        if declared.is_a?(Array) && !declared.empty?
          entries = declared
                    .map { |ext_path| File.expand_path(ext_path, dir) }
                    .select { |resolved| File.exist?(resolved) }
          return entries unless entries.empty?
        end
      end

      index_rb = File.join(dir, "index.rb")
      return [File.expand_path(index_rb)] if File.exist?(index_rb)

      nil
    end

    # Every extension entry path discovered one level deep under `dir`. Ports
    # discoverExtensionsInDir: a missing directory or an unreadable one yields an
    # empty list; otherwise each direct `.rb` file is an entry, and each
    # subdirectory contributes whatever resolve_entries finds for it.
    #
    # The symlink handling mirrors pi's dirent test. Node reports a symlink's own
    # type without following it, so pi treats a symlink named like an extension
    # file as a direct entry (even a dangling one) and otherwise tries it as a
    # subdirectory. File.symlink? gives the same un-followed view here, while
    # File.file? / File.directory? follow the link for the plain cases.
    def discover_in_dir(dir)
      return [] unless File.directory?(dir)

      discovered = []
      entries = Dir.children(dir).sort
      entries.each do |name|
        entry_path = File.join(dir, name)

        if (File.file?(entry_path) || File.symlink?(entry_path)) && extension_file?(name)
          discovered << entry_path
          next
        end

        if File.directory?(entry_path) || File.symlink?(entry_path)
          resolved = resolve_entries(entry_path)
          discovered.concat(resolved) if resolved
        end
      end

      discovered
    rescue StandardError
      []
    end
  end
end
