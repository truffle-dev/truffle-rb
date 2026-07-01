# frozen_string_literal: true

module Truffle
  # Process-local OpenAI-compatible provider registrations. This is the same
  # provider-config shape extensions use, but available to embedding apps without
  # writing and loading an extension file.
  module ProviderRegistry
    @registrations = []

    ProviderDefinition = Struct.new(:name, :config, keyword_init: true) do
      def initialize(name:, config:)
        copied = ProviderRegistry.deep_dup_config(config)
        super(name: name.to_s, config: ProviderRegistry.deep_freeze_config(copied))
        freeze
      end

      def display_name
        config[:display_name]&.to_s || name
      end

      def api
        config[:api]
      end

      def model_ids
        ids = []
        ids << config[:model].to_s if config[:model]
        Array(config[:models]).each do |model|
          id = ProviderRegistry.model_id(model)
          ids << id if id
        end
        ids.uniq.freeze
      end
    end

    # A small runtime view over process and extension provider registrations.
    # It mirrors pi's provider collection shape where it helps Ruby apps today:
    # list providers, look up models, and mutate the process-local registry.
    # Request binding still happens through Truffle.provider, so unsupported APIs
    # remain inspectable here but fail clearly when used for a chat request.
    class Collection
      def initialize(extensions: nil)
        @extensions = extensions
      end

      def providers
        provider_entries.map do |name, config|
          ProviderDefinition.new(name: name, config: config)
        end.freeze
      end

      def provider_names
        providers.map(&:name)
      end

      def get_provider(name)
        providers.find { |provider| provider.name.casecmp?(name.to_s) }
      end

      def model_references
        Extensions.model_references(provider_source)
      end

      def get_model(provider, id)
        provider_name = provider.to_s
        model_id = id.to_s
        model_references.find do |model|
          model.provider.casecmp?(provider_name) && model.model_id.casecmp?(model_id)
        end
      end

      def resolve_model(reference)
        Extensions.model_reference(provider_source, reference)
      end

      def set_provider(name, config)
        ensure_process_mutable!("set_provider")
        ProviderRegistry.register(name, config)
      end

      def delete_provider(name)
        ensure_process_mutable!("delete_provider")
        ProviderRegistry.unregister(name)
      end

      private

      def provider_entries
        entries = process_entries
        extension_entries.each do |name, config|
          index = entries.index { |existing_name, _| existing_name.casecmp?(name) }
          if index
            entries[index] = [name, config]
          else
            entries << [name, config]
          end
        end
        entries
      end

      def process_entries
        Extensions.provider_config_entries(ProviderRegistry.registrations)
      end

      def extension_entries
        Extensions.provider_config_entries(@extensions)
      end

      def provider_source
        provider_entries.map do |name, config|
          Extensions::ProviderRegistration.new(
            name: name,
            config: config,
            source_path: nil
          )
        end
      end

      def ensure_process_mutable!(action)
        return if @extensions.nil?

        raise Error, "#{action} is only supported on the process provider registry"
      end
    end

    class << self
      def register(name, config)
        @registrations << Extensions::ProviderRegistration.new(
          name: name.to_s,
          config: config,
          source_path: nil
        )
        nil
      end

      def registrations
        @registrations.dup
      end

      def unregister(name)
        provider_name = name.to_s
        @registrations.reject! { |registration| registration.name.casecmp?(provider_name) }
        nil
      end

      def clear
        @registrations.clear
        nil
      end

      def provider_names
        Extensions.provider_names(@registrations)
      end

      def provider_options(name)
        Extensions.provider_options(@registrations, name)
      end

      def model_reference(reference)
        Extensions.model_reference(@registrations, reference)
      end

      def collection(extensions: nil)
        Collection.new(extensions: extensions)
      end

      def deep_dup_config(value)
        case value
        when Hash
          value.each_with_object({}) { |(key, item), copy| copy[key] = deep_dup_config(item) }
        when Array
          value.map { |item| deep_dup_config(item) }
        else
          value
        end
      end

      def deep_freeze_config(value)
        case value
        when Hash
          value.each_value { |item| deep_freeze_config(item) }
        when Array
          value.each { |item| deep_freeze_config(item) }
        end
        value.freeze
      end

      def model_id(model)
        case model
        when String, Symbol
          model.to_s
        when Hash
          (model[:id] || model["id"])&.to_s
        end
      end
    end
  end
end
