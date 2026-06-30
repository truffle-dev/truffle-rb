# frozen_string_literal: true

require_relative "../extensions"
require_relative "../models"
require_relative "config_values"

module Truffle
  module Extensions
    ModelReference = Struct.new(:provider, :model_id, keyword_init: true)

    OPENAI_COMPATIBLE_APIS = %w[
      openai openai_completions openai-completions
      chat_completions chat-completions
    ].freeze

    module_function

    # Provider configs registered by loaded extensions, in effective order. A
    # LoadResult keeps the shared runtime queue so cross-file unregister calls are
    # respected; bare Extension objects expose only their own registrations.
    def provider_registrations(source)
      case source
      when nil
        []
      when LoadResult
        source.runtime.provider_registrations
      when Extension
        source.provider_registrations
      else
        Array(source).flat_map { |item| provider_registrations(item) }
      end
    end

    def provider_names(source)
      provider_configs(source).keys
    end

    def provider_options(source, provider_name)
      entry = provider_config_entry(source, provider_name)
      return nil unless entry

      name, config = entry
      api = provider_api(config)
      unless api.nil? || openai_compatible_api?(api)
        raise Error, "extension provider #{name.inspect} uses unsupported api #{api.inspect}; " \
                     "only OpenAI-compatible chat providers are supported"
      end

      options = { provider_name: name.to_s }
      options[:base_url] = config[:base_url].to_s if config[:base_url]
      api_key = provider_api_key(name, config[:api_key])
      options[:api_key] = api_key if api_key
      headers = provider_headers(name, config[:headers])
      options[:headers] = headers if headers
      model_headers = provider_model_headers(name, config[:models])
      options[:model_headers] = model_headers if model_headers
      options[:auth_header] = config[:auth_header] if config.key?(:auth_header)
      model_id = config[:model] || first_model_id(config[:models])
      options[:model] = model_id.to_s if model_id
      options
    end

    def model_reference(source, reference)
      trimmed = reference.to_s.strip
      return nil if trimmed.empty?

      references = provider_model_references(source)
      match = one_model_reference(references) do |model|
        "#{model.provider}/#{model.model_id}".casecmp?(trimmed)
      end
      return match if match

      match = model_reference_with_provider(trimmed, references)
      return match if match

      one_model_reference(references) { |model| model_id_match?(model.model_id, trimmed) }
    end

    def provider_configs(source)
      configs = {}
      provider_registrations(source).each do |registration|
        key = provider_config_key(configs, registration.name)
        normalized = normalize_provider_config(registration.config)
        configs[key] = merge_provider_config(configs[key], normalized)
      end
      configs
    end
    private_class_method :provider_configs

    def provider_config_entry(source, provider_name)
      wanted = provider_name.to_s
      provider_configs(source).find { |name, _config| name.casecmp?(wanted) }
    end
    private_class_method :provider_config_entry

    def provider_config_key(configs, provider_name)
      name = provider_name.to_s
      configs.keys.find { |existing| existing.casecmp?(name) } || name
    end
    private_class_method :provider_config_key

    def merge_provider_config(existing, incoming)
      merged = (existing || {}).dup
      incoming.each do |key, value|
        next if value.nil?

        merged[key] = value
      end
      merged
    end
    private_class_method :merge_provider_config

    def normalize_provider_config(config)
      return {} unless config.is_a?(Hash)

      config.each_with_object({}) do |(key, value), normalized|
        case key.to_s
        when "name"
          normalized[:display_name] = value
        when "baseUrl", "base_url"
          normalized[:base_url] = value
        when "apiKey", "api_key"
          normalized[:api_key] = value
        when "api"
          normalized[:api] = value
        when "authHeader", "auth_header"
          normalized[:auth_header] = value
        when "headers"
          normalized[:headers] = value
        when "model"
          normalized[:model] = value
        when "models"
          normalized[:models] = value
        end
      end
    end
    private_class_method :normalize_provider_config

    def provider_api(config)
      config[:api] || Array(config[:models]).filter_map { |model| model_value(model, :api) }.first
    end
    private_class_method :provider_api

    def openai_compatible_api?(api)
      OPENAI_COMPATIBLE_APIS.include?(api.to_s)
    end
    private_class_method :openai_compatible_api?

    def provider_api_key(provider_name, value)
      return nil if value.nil?

      ConfigValues.resolve(value, provider_name: provider_name, label: "api_key")
    end
    private_class_method :provider_api_key

    def provider_headers(provider_name, headers, label_prefix: "header")
      return nil unless headers.is_a?(Hash)

      resolved = headers.each_with_object({}) do |(key, value), acc|
        resolved_value = ConfigValues.resolve(
          value,
          provider_name: provider_name,
          label: "#{label_prefix} #{key}"
        )
        acc[key.to_s] = resolved_value if resolved_value
      end
      resolved.empty? ? nil : resolved
    end
    private_class_method :provider_headers

    def provider_model_headers(provider_name, models)
      resolved = Array(models).each_with_object({}) do |model, acc|
        id = model_id(model)
        next unless id

        headers = provider_headers(
          provider_name,
          model_value(model, :headers),
          label_prefix: "model #{id} header"
        )
        acc[id.to_s] = headers if headers
      end
      resolved.empty? ? nil : resolved
    end
    private_class_method :provider_model_headers

    def provider_model_references(source)
      provider_configs(source).flat_map do |provider, config|
        ids = []
        ids << config[:model] if config[:model]
        ids.concat(Array(config[:models]).filter_map { |model| model_id(model) })
        ids.uniq.map do |model_id|
          ModelReference.new(provider: provider, model_id: model_id.to_s)
        end
      end
    end
    private_class_method :provider_model_references

    def first_model_id(models)
      Array(models).filter_map { |model| model_id(model) }.first
    end
    private_class_method :first_model_id

    def model_id(model)
      case model
      when String, Symbol
        model.to_s
      else
        model_value(model, :id)&.to_s
      end
    end
    private_class_method :model_id

    def model_value(model, key)
      return nil unless model.is_a?(Hash)

      camel = key.to_s.gsub(/_([a-z])/) { Regexp.last_match(1).upcase }
      [key, key.to_s, camel].each do |candidate|
        return model[candidate] if model.key?(candidate)
      end
      nil
    end
    private_class_method :model_value

    def one_model_reference(references, &)
      matches = references.select(&)
      matches.length == 1 ? matches.first : nil
    end
    private_class_method :one_model_reference

    def model_reference_with_provider(reference, references)
      slash = reference.index("/")
      return nil unless slash

      provider = reference[0...slash].strip
      model_id = reference[(slash + 1)..].strip
      return nil if provider.empty? || model_id.empty?

      one_model_reference(references) do |model|
        model.provider.casecmp?(provider) && model_id_match?(model.model_id, model_id)
      end
    end
    private_class_method :model_reference_with_provider

    def model_id_match?(id, reference)
      id.downcase == reference.downcase || id.downcase == Models.base_id(reference.downcase)
    end
    private_class_method :model_id_match?
  end
end
