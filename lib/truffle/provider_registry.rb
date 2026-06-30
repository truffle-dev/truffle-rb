# frozen_string_literal: true

module Truffle
  # Process-local OpenAI-compatible provider registrations. This is the same
  # provider-config shape extensions use, but available to embedding apps without
  # writing and loading an extension file.
  module ProviderRegistry
    @registrations = []

    class << self
      def register(name, config)
        @registrations << Extensions::ProviderRegistration.new(
          name: name.to_s,
          config: config,
          source_path: nil
        )
        nil
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
    end
  end
end
