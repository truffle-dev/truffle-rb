# frozen_string_literal: true

require "test_helper"

# Tests for the offline model-catalog table behind `truffle --list-models`.
class TestCLIModels < Minitest::Test
  def test_models_text_prints_an_aligned_catalog_table
    text = Truffle::CLI.models_text

    assert text.start_with?("provider")
    assert_includes text, "model"
    assert_includes text, "context"
    assert_match(/^anthropic\s+claude-haiku-4-5\s+200K\s+64K\s+yes\s+yes$/, text)
    assert_match(/^openai\s+gpt-4o-mini\s+128K\s+16.4K\s+no\s+yes$/, text)
    assert text.end_with?("\n")
  end

  def test_models_text_filters_with_a_fuzzy_search_pattern
    text = Truffle::CLI.models_text(search: "sonnet")

    assert_includes text, "claude-sonnet-4-5"
    assert_includes text, "claude-sonnet-4-6"
    refute_includes text, "gpt-4o-mini"
  end

  def test_models_text_reports_no_matches
    assert_equal "No models matching \"not-a-real-model\"\n",
                 Truffle::CLI.models_text(search: "not-a-real-model")
  end

  def test_models_text_reports_an_empty_catalog
    assert_equal "No models available\n", Truffle::CLI.models_text(models: [])
  end
end
