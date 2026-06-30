# frozen_string_literal: true

require "json"
require_relative "config"
require_relative "event_bus"
require_relative "slash_commands"
require_relative "tool"

module Truffle
  # Extension discovery, the Ruby port of the pure filesystem layer in pi's
  # extension loader (packages/coding-agent/src/core/extensions/loader.ts). This
  # is the seam that finds extension *entry points* on disk before anything is
  # bound into the agent. A discovered Ruby entry can also be evaluated with a
  # load-time registration API; binding those registrations into live sessions
  # is a later runtime concern.
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
    Extension = Struct.new(:path, :resolved_path, :handlers, :tools, :commands,
                           :provider_registrations, keyword_init: true)
    RegisteredTool = Struct.new(:definition, :source_path, keyword_init: true)
    ProviderRegistration = Struct.new(:name, :config, :source_path, keyword_init: true)
    LoadError = Struct.new(:path, :error, keyword_init: true)
    HandlerError = Struct.new(:extension_path, :event, :error, :exception, keyword_init: true)
    LoadResult = Struct.new(:extensions, :errors, :runtime, keyword_init: true)

    STALE_CONTEXT_MESSAGE =
      "This extension API is stale after extension runtime invalidation."

    # Shared extension runtime state. pi creates one runtime and hands every
    # extension API a reference to it; registration works during load, while
    # later binding replaces the action methods. This Ruby slice keeps only the
    # load-time state that already has a concrete host: event-bus access and
    # queued provider registrations.
    class Runtime
      attr_reader :events, :provider_registrations

      def initialize(events: EventBus.new)
        @events = events
        @provider_registrations = []
        @stale_message = nil
      end

      def assert_active
        raise Error, @stale_message if @stale_message
      end

      def invalidate(message = STALE_CONTEXT_MESSAGE)
        return if @stale_message

        @stale_message = message
      end

      def register_provider(name, config, source_path)
        provider_registrations << ProviderRegistration.new(
          name: name.to_s,
          config: config,
          source_path: source_path
        )
      end

      def unregister_provider(name)
        provider_name = name.to_s
        provider_registrations.reject! { |registration| registration.name == provider_name }
      end
    end

    # The object exposed to a Ruby extension file as `truffle`. Its registration
    # methods write into the current Extension; action methods that need a bound
    # UI/session/runtime are deliberately left for a later item-18 slice.
    class API
      attr_reader :extension, :runtime

      def initialize(extension:, runtime:)
        @extension = extension
        @runtime = runtime
      end

      def on(event, handler = nil, &block)
        runtime.assert_active
        callable = handler || block
        raise ArgumentError, "on requires a handler or block" unless callable

        event_name = event.to_s
        (extension.handlers[event_name] ||= []) << callable
        callable
      end

      def register_tool(tool)
        runtime.assert_active
        raise ArgumentError, "register_tool expects a Truffle::Tool" unless tool.is_a?(Tool)

        extension.tools[tool.name] = RegisteredTool.new(
          definition: tool,
          source_path: extension.path
        )
        tool
      end

      def register_command(name, description: nil, handler: nil, **, &block)
        runtime.assert_active
        callable = handler || block
        raise ArgumentError, "register_command requires a handler or block" unless callable

        command = SlashCommands::Command.new(
          name: name.to_s,
          description: description,
          source: :extension,
          handler: command_handler(callable)
        )
        extension.commands[command.name] = command
        command
      end

      def register_provider(name, config)
        runtime.assert_active
        extension.provider_registrations << ProviderRegistration.new(
          name: name.to_s,
          config: config,
          source_path: extension.path
        )
        runtime.register_provider(name, config, extension.path)
        nil
      end

      def unregister_provider(name)
        runtime.assert_active
        provider_name = name.to_s
        extension.provider_registrations.reject! do |registration|
          registration.name == provider_name
        end
        runtime.unregister_provider(name)
        nil
      end

      def events
        runtime.assert_active
        runtime.events
      end

      private

      def command_handler(callable)
        lambda do |args_string|
          case callable.arity
          when 0
            callable.call
          when 1, -1
            callable.call(args_string)
          else
            callable.call(args_string, nil)
          end
        end
      end
    end

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

    # Load one Ruby extension file. The file is evaluated with a single helper
    # method, `truffle`, returning the extension API. This is the Ruby analogue
    # of pi importing a default factory and calling it with `ExtensionAPI`.
    def load_file(file_path, cwd: Dir.pwd, runtime: Runtime.new)
      resolved_path = File.expand_path(file_path, cwd)
      extension = build_extension(file_path, resolved_path)
      api = API.new(extension: extension, runtime: runtime)
      loader = Object.new
      loader.define_singleton_method(:truffle) { api }
      loader.instance_eval(File.read(resolved_path), resolved_path, 1)
      extension
    end

    # Load several extension files, collecting per-file errors so one broken
    # extension does not stop the rest. This mirrors pi's LoadExtensionsResult.
    def load_files(paths, cwd: Dir.pwd, runtime: Runtime.new)
      extensions = []
      errors = []

      Array(paths).each do |path|
        extensions << load_file(path, cwd: cwd, runtime: runtime)
      rescue StandardError, ScriptError => e
        errors << LoadError.new(path: path, error: "Failed to load extension: #{e.message}")
      end

      LoadResult.new(extensions: extensions, errors: errors, runtime: runtime)
    end

    # Discover and load extension entries in pi's standard order: project
    # `.truffle/extensions`, user `agent_dir/extensions`, then explicit paths.
    # Explicit directories first resolve as an extension package/index; otherwise
    # their direct children are discovered. Paths are de-duplicated after
    # expansion, matching pi's path.resolve-based `seen` set.
    def load_all(extension_paths: [], cwd: Dir.pwd, agent_dir: Config.agent_dir,
                 runtime: Runtime.new, include_defaults: true,
                 include_project: true, include_user: true)
      paths = []
      seen = {}
      add_paths = lambda do |candidates|
        Array(candidates).each do |candidate|
          expanded = File.expand_path(candidate)
          next if seen[expanded]

          seen[expanded] = true
          paths << expanded
        end
      end

      if include_defaults
        if include_project
          add_paths.call(discover_in_dir(File.join(Config.project_dir(cwd: cwd), "extensions")))
        end
        if include_user
          add_paths.call(discover_in_dir(File.join(File.expand_path(agent_dir), "extensions")))
        end
      end

      Array(extension_paths).each do |path|
        raw_path = path.to_s.strip
        next if raw_path.empty?

        resolved = File.expand_path(raw_path, cwd)

        if File.directory?(resolved)
          entries = resolve_entries(resolved)
          add_paths.call(entries || discover_in_dir(resolved))
        else
          add_paths.call([resolved])
        end
      end

      load_files(paths, cwd: cwd, runtime: runtime)
    end

    # Normalize a loaded extension source. Callers may pass one Extension, one
    # LoadResult, or an array mixing both. This keeps agent binding code small
    # while preserving the loader's result object for diagnostics.
    def loaded(source)
      case source
      when nil
        []
      when LoadResult
        source.extensions
      when Extension
        [source]
      else
        Array(source).flat_map { |item| loaded(item) }
      end
    end

    # Tool definitions registered by loaded extensions. The first extension to
    # register a tool name wins, matching pi's ExtensionRunner.
    def tool_definitions(source)
      by_name = {}
      loaded(source).each do |extension|
        extension.tools.each_value do |registered|
          by_name[registered.definition.name] ||= registered.definition
        end
      end
      by_name.values
    end

    # Slash commands registered by loaded extensions, in extension load order.
    # Duplicate invocation names are resolved by SlashCommands::Registry.
    def command_definitions(source)
      loaded(source).flat_map { |extension| extension.commands.values }
    end

    # Dispatch one event to handlers registered by loaded extensions. Handlers
    # run in extension load order, and in registration order within each
    # extension. A raising handler is returned as a HandlerError and does not stop
    # later handlers, matching pi's ExtensionRunner error isolation.
    def dispatch_handlers(source, event, payload = {}, context: nil)
      event_name = event.to_s
      event_payload = payload.merge(type: event_name)
      errors = []

      loaded(source).each do |extension|
        Array(extension.handlers[event_name]).each do |handler|
          call_handler(handler, event_payload.dup, context)
        rescue StandardError => e
          errors << HandlerError.new(
            extension_path: extension.path,
            event: event_name,
            error: "#{e.class}: #{e.message}",
            exception: e
          )
        end
      end

      errors
    end

    def build_extension(path, resolved_path)
      Extension.new(
        path: path,
        resolved_path: resolved_path,
        handlers: {},
        tools: {},
        commands: {},
        provider_registrations: []
      )
    end
    private_class_method :build_extension

    def call_handler(handler, event_payload, context)
      arity = handler.arity
      if arity.zero?
        handler.call
      elsif arity == 1 || [-1, -2].include?(arity)
        handler.call(event_payload)
      else
        handler.call(event_payload, context)
      end
    end
    private_class_method :call_handler
  end
end
