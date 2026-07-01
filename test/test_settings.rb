# frozen_string_literal: true

require "test_helper"
require "json"
require "tmpdir"
require "fileutils"

class TestSettings < Minitest::Test
  def write_settings(dir, value)
    FileUtils.mkdir_p(File.join(dir, ".truffle"))
    File.write(File.join(dir, ".truffle", "settings.json"), "#{JSON.pretty_generate(value)}\n")
  end

  def test_missing_project_settings_loads_empty_settings
    Dir.mktmpdir("truffle-settings") do |dir|
      settings = Truffle::Settings.load_project(cwd: dir)

      assert_equal({}, settings.to_h)
      assert_nil settings.default_provider
      assert_nil settings.default_model
      assert_equal File.join(dir, ".truffle", "settings.json"), settings.path
    end
  end

  def test_project_settings_can_be_skipped_when_untrusted
    Dir.mktmpdir("truffle-settings") do |dir|
      write_settings(dir, "defaultProvider" => "openai")

      settings = Truffle::Settings.load_project(cwd: dir, trusted: false)

      assert_equal({}, settings.to_h)
      assert_nil settings.default_provider
    end
  end

  def test_loads_pi_style_runtime_settings
    Dir.mktmpdir("truffle-settings") do |dir|
      write_settings(
        dir,
        "defaultProvider" => "openai",
        "defaultModel" => "gpt-4o-mini",
        "compaction" => {
          "enabled" => false,
          "reserveTokens" => 12_000,
          "keepRecentTokens" => 8_000
        },
        "retry" => {
          "enabled" => false,
          "maxRetries" => 1,
          "baseDelayMs" => 25,
          "maxDelayMs" => 500
        }
      )

      settings = Truffle::Settings.load_project(cwd: dir)

      assert_equal "openai", settings.default_provider
      assert_equal "gpt-4o-mini", settings.default_model
      refute settings.compaction_settings.enabled
      assert_equal 12_000, settings.compaction_settings.reserve_tokens
      assert_equal 8_000, settings.compaction_settings.keep_recent_tokens
      assert_equal({
                     enabled: false,
                     max_retries: 1,
                     base_delay_ms: 25,
                     max_delay_ms: 500
                   }, settings.retry_settings)
    end
  end

  def test_loads_ruby_style_aliases
    Dir.mktmpdir("truffle-settings") do |dir|
      write_settings(
        dir,
        "default_provider" => "anthropic",
        "default_model" => "claude-sonnet-4-5",
        "compaction" => { "reserve_tokens" => 100, "keep_recent_tokens" => 50 },
        "retry" => { "max_retries" => 2, "base_delay_ms" => 10, "max_delay_ms" => 20 }
      )

      settings = Truffle::Settings.load_project(cwd: dir)

      assert_equal "anthropic", settings.default_provider
      assert_equal "claude-sonnet-4-5", settings.default_model
      assert_equal 100, settings.compaction_settings.reserve_tokens
      assert_equal 50, settings.compaction_settings.keep_recent_tokens
      assert_equal 2, settings.retry_settings[:max_retries]
      assert_equal 10, settings.retry_settings[:base_delay_ms]
      assert_equal 20, settings.retry_settings[:max_delay_ms]
    end
  end

  def test_malformed_values_fall_back_to_runtime_defaults
    Dir.mktmpdir("truffle-settings") do |dir|
      write_settings(
        dir,
        "defaultProvider" => "",
        "defaultModel" => 123,
        "compaction" => { "enabled" => "no", "reserveTokens" => "large" },
        "retry" => { "maxRetries" => "many", "baseDelayMs" => nil }
      )

      settings = Truffle::Settings.load_project(cwd: dir)

      assert_nil settings.default_provider
      assert_nil settings.default_model
      assert_equal Truffle::Compaction::DEFAULT_SETTINGS, settings.compaction_settings
      assert_equal Truffle::Settings::DEFAULT_RETRY_SETTINGS, settings.retry_settings
    end
  end

  def test_to_h_returns_a_copy
    settings = Truffle::Settings.new({ "retry" => { "maxRetries" => 1 } })

    copy = settings.to_h
    copy["retry"]["maxRetries"] = 99

    assert_equal 1, settings.to_h["retry"]["maxRetries"]
  end

  def test_invalid_json_raises_a_truffle_error
    Dir.mktmpdir("truffle-settings") do |dir|
      FileUtils.mkdir_p(File.join(dir, ".truffle"))
      File.write(File.join(dir, ".truffle", "settings.json"), "{")

      error = assert_raises(Truffle::Error) { Truffle::Settings.load_project(cwd: dir) }

      assert_includes error.message, "invalid settings file"
    end
  end

  def test_non_object_json_raises_a_truffle_error
    Dir.mktmpdir("truffle-settings") do |dir|
      FileUtils.mkdir_p(File.join(dir, ".truffle"))
      File.write(File.join(dir, ".truffle", "settings.json"), "[]")

      error = assert_raises(Truffle::Error) { Truffle::Settings.load_project(cwd: dir) }

      assert_includes error.message, "settings file must contain a JSON object"
    end
  end
end
