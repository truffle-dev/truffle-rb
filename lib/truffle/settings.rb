# frozen_string_literal: true

require "json"

module Truffle
  # Read-only runtime settings loaded from `.truffle/settings.json`.
  #
  # This is the first project-settings slice, modeled on pi's SettingsManager
  # getters but narrowed to settings this Ruby runtime already understands:
  # default provider/model, compaction thresholds, and retry policy.
  class Settings
    DEFAULT_RETRY_SETTINGS = {
      enabled: true,
      max_retries: 3,
      base_delay_ms: 2000,
      max_delay_ms: 60_000
    }.freeze

    attr_reader :path

    def self.empty(path: nil)
      new({}, path: path)
    end

    def self.load_project(cwd: Dir.pwd, trusted: true)
      path = Config.project_settings_path(cwd: cwd)
      return empty(path: path) unless trusted && File.file?(path)

      parsed = JSON.parse(File.read(path, encoding: "UTF-8"))
      raise Error, "settings file must contain a JSON object: #{path}" unless parsed.is_a?(Hash)

      new(parsed, path: path)
    rescue JSON::ParserError => e
      raise Error, "invalid settings file #{path}: #{e.message}"
    end

    def initialize(values, path: nil)
      @values = deep_freeze(values)
      @path = path
    end

    def to_h
      deep_dup(@values)
    end

    def default_provider
      string_value(@values, "defaultProvider", "default_provider")
    end

    def default_model
      string_value(@values, "defaultModel", "default_model")
    end

    def compaction_settings
      raw = object_value(@values, "compaction") || {}
      defaults = Compaction::DEFAULT_SETTINGS
      Compaction::Settings.new(
        enabled: boolean_value(raw, defaults.enabled, "enabled"),
        reserve_tokens: integer_value(raw, defaults.reserve_tokens,
                                      "reserveTokens", "reserve_tokens"),
        keep_recent_tokens: integer_value(raw, defaults.keep_recent_tokens,
                                          "keepRecentTokens", "keep_recent_tokens")
      )
    end

    def retry_settings
      raw = object_value(@values, "retry") || {}
      defaults = DEFAULT_RETRY_SETTINGS
      {
        enabled: boolean_value(raw, defaults[:enabled], "enabled"),
        max_retries: integer_value(raw, defaults[:max_retries],
                                   "maxRetries", "max_retries"),
        base_delay_ms: integer_value(raw, defaults[:base_delay_ms],
                                     "baseDelayMs", "base_delay_ms"),
        max_delay_ms: integer_value(raw, defaults[:max_delay_ms],
                                    "maxDelayMs", "max_delay_ms")
      }
    end

    private

    def string_value(hash, *keys)
      value = fetch(hash, *keys)
      value.is_a?(String) && !value.empty? ? value : nil
    end

    def object_value(hash, *keys)
      value = fetch(hash, *keys)
      value.is_a?(Hash) ? value : nil
    end

    def boolean_value(hash, fallback, *keys)
      value = fetch(hash, *keys)
      [true, false].include?(value) ? value : fallback
    end

    def integer_value(hash, fallback, *keys)
      value = fetch(hash, *keys)
      value.is_a?(Numeric) && value.finite? ? value.to_i : fallback
    end

    def fetch(hash, *keys)
      keys.each do |key|
        return hash[key] if hash.key?(key)
      end
      nil
    end

    def deep_dup(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, item), copy| copy[key] = deep_dup(item) }
      when Array
        value.map { |item| deep_dup(item) }
      else
        value
      end
    end

    def deep_freeze(value)
      case value
      when Hash
        value.each_value { |item| deep_freeze(item) }
      when Array
        value.each { |item| deep_freeze(item) }
      end
      value.freeze
    end
  end
end
