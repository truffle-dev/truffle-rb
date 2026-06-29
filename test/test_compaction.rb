# frozen_string_literal: true

require "test_helper"

# The compaction decision layer: estimating how many context tokens a
# conversation uses and deciding when that crosses the threshold to summarize.
# Pure and offline, so the estimates are pinned to exact values.
class TestCompaction < Minitest::Test
  Compaction = Truffle::Compaction

  def test_estimate_tokens_counts_user_text_at_four_chars_per_token
    message = Truffle::Message.user("hello world") # 11 chars -> ceil(11/4) = 3

    assert_equal 3, Compaction.estimate_tokens(message)
  end

  def test_estimate_tokens_charges_an_image_a_flat_budget
    image = Truffle::Content::Image.new(data: "x", mime_type: "image/png")
    message = Truffle::Message.user([image]) # 4800 chars -> ceil(4800/4) = 1200

    assert_equal 1200, Compaction.estimate_tokens(message)
  end

  def test_estimate_tokens_counts_assistant_thinking_and_text
    blocks = [
      Truffle::Content::Thinking.new(thinking: "abcd"), # 4
      Truffle::Content::Text.new(text: "xy") # 2
    ]
    message = Truffle::Message.assistant(content: blocks) # 6 chars -> ceil(6/4) = 2

    assert_equal 2, Compaction.estimate_tokens(message)
  end

  def test_estimate_tokens_counts_a_tool_call_name_and_arguments
    call = Truffle::ToolCall.new(id: "1", name: "add", arguments: { "a" => 1, "b" => 2 })
    message = Truffle::Message.assistant(tool_calls: [call])
    # "add" (3) + {"a":1,"b":2} (13) = 16 -> ceil(16/4) = 4
    assert_equal 4, Compaction.estimate_tokens(message)
  end

  def test_estimate_tokens_ignores_the_system_prompt
    message = Truffle::Message.system("x" * 100)

    assert_equal 0, Compaction.estimate_tokens(message)
  end

  def test_calculate_context_tokens_sums_the_usage_classes
    usage = Truffle::Usage.new(input: 100, output: 50, cache_read: 10, cache_write: 5)

    assert_equal 165, Compaction.calculate_context_tokens(usage)
  end

  def test_estimate_context_tokens_sums_the_messages_without_usage
    messages = [Truffle::Message.user("hello world"), Truffle::Message.assistant(content: "ok")]
    # 3 + ceil(2/4)=1 = 4
    assert_equal 4, Compaction.estimate_context_tokens(messages)
  end

  def test_estimate_context_tokens_adds_trailing_messages_to_a_known_usage
    usage = Truffle::Usage.new(input: 100, output: 50, cache_read: 10, cache_write: 5) # 165
    trailing = [Truffle::Message.tool(content: "abcd", tool_call_id: "1")] # 4 chars -> 1

    assert_equal 166, Compaction.estimate_context_tokens(trailing, usage: usage)
  end

  def test_should_compact_when_context_exceeds_the_window_less_reserve
    settings = Compaction::Settings.new(enabled: true, reserve_tokens: 100, keep_recent_tokens: 0)

    assert Compaction.should_compact?(901, 1000, settings)
  end

  def test_should_not_compact_at_the_threshold
    settings = Compaction::Settings.new(enabled: true, reserve_tokens: 100, keep_recent_tokens: 0)
    # threshold is 1000 - 100 = 900; exactly at it does not yet compact
    refute Compaction.should_compact?(900, 1000, settings)
  end

  def test_should_not_compact_when_disabled
    settings = Compaction::Settings.new(enabled: false, reserve_tokens: 100, keep_recent_tokens: 0)

    refute Compaction.should_compact?(10_000, 1000, settings)
  end

  def test_default_settings_match_pi
    assert Compaction::DEFAULT_SETTINGS.enabled
    assert_equal 16_384, Compaction::DEFAULT_SETTINGS.reserve_tokens
    assert_equal 20_000, Compaction::DEFAULT_SETTINGS.keep_recent_tokens
  end
end
