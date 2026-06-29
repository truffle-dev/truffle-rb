# frozen_string_literal: true

require "test_helper"

# The summarizer half of compaction: the provider-calling functions that turn a
# stretch of history into a structured summary. The provider is stubbed, so these
# stay offline and assert the prompt, the output-token cap, and the error mapping.
class TestCompactionSummarizer < Minitest::Test
  Compaction = Truffle::Compaction

  # A throwaway model with a chosen max output, so the token-cap tests do not
  # depend on the shipped catalog (whose numbers change when models.rb is updated).
  def summary_model(max_output:)
    Truffle::Model.new(
      id: "test-model", name: "Test", provider: :openai, api: :chat_completions,
      context_window: 128_000, max_output: max_output,
      cost: { input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0 }
    )
  end

  def error_response(message)
    Truffle::Response.new(
      message: Truffle::Message.assistant(content: "ignored"),
      stop_reason: Truffle::StopReason::ERROR, error_message: message
    )
  end

  def aborted_response
    Truffle::Response.new(
      message: Truffle::Message.assistant(content: ""),
      stop_reason: Truffle::StopReason::ABORTED
    )
  end

  def test_generate_summary_returns_the_models_summary_text
    provider = StubProvider.new([StubProvider.text("## Goal\nship it")])

    summary = Compaction.generate_summary(
      provider, summary_model(max_output: 0),
      [Truffle::Message.user("do the thing")], reserve_tokens: 16_384
    )

    assert_equal "## Goal\nship it", summary
  end

  def test_generate_summary_sends_the_summarizer_system_prompt_and_the_built_prompt
    provider = StubProvider.new([StubProvider.text("ok")])

    Compaction.generate_summary(
      provider, summary_model(max_output: 0),
      [Truffle::Message.user("how do I sort")], reserve_tokens: 16_384
    )

    sent = provider.calls.first[:messages]

    assert_equal "system", sent.first[:role].to_s
    assert_equal Compaction::SUMMARIZATION_SYSTEM_PROMPT, sent.first[:content].first[:text]
    user_text = sent.last[:content].first[:text]

    assert_includes user_text, "<conversation>\n[User]: how do I sort\n</conversation>"
    assert_includes user_text, "Create a structured context checkpoint summary"
  end

  def test_generate_summary_joins_multiple_text_blocks_with_newlines
    blocks = [
      Truffle::Content::Text.new(text: "first"),
      Truffle::Content::Text.new(text: "second")
    ]
    provider = StubProvider.new([
                                  Truffle::Response.new(
                                    message: Truffle::Message.assistant(content: blocks),
                                    stop_reason: Truffle::StopReason::STOP
                                  )
                                ])

    summary = Compaction.generate_summary(
      provider, summary_model(max_output: 0),
      [Truffle::Message.user("hi")], reserve_tokens: 1000
    )

    assert_equal "first\nsecond", summary
  end

  def test_generate_summary_caps_output_at_the_reserve_fraction_when_uncapped_by_model
    provider = StubProvider.new([StubProvider.text("ok")])

    Compaction.generate_summary(
      provider, summary_model(max_output: 0),
      [Truffle::Message.user("hi")], reserve_tokens: 1000
    )

    # floor(0.8 * 1000), with no model cap.
    assert_equal 800, provider.calls.first[:options][:max_tokens]
  end

  def test_generate_summary_caps_output_at_the_model_max_when_lower
    provider = StubProvider.new([StubProvider.text("ok")])

    Compaction.generate_summary(
      provider, summary_model(max_output: 256),
      [Truffle::Message.user("hi")], reserve_tokens: 1000
    )

    # min(floor(0.8 * 1000), 256).
    assert_equal 256, provider.calls.first[:options][:max_tokens]
  end

  def test_generate_turn_prefix_summary_uses_the_tighter_half_reserve_cap
    provider = StubProvider.new([StubProvider.text("ok")])

    Compaction.generate_turn_prefix_summary(
      provider, summary_model(max_output: 0),
      [Truffle::Message.user("hi")], reserve_tokens: 1000
    )

    # floor(0.5 * 1000).
    assert_equal 500, provider.calls.first[:options][:max_tokens]
    user_text = provider.calls.first[:messages].last[:content].first[:text]

    assert_includes user_text, "This is the PREFIX of a turn that was too large to keep"
  end

  def test_generate_summary_folds_in_a_previous_summary
    provider = StubProvider.new([StubProvider.text("ok")])

    Compaction.generate_summary(
      provider, summary_model(max_output: 0),
      [Truffle::Message.user("more")], reserve_tokens: 1000, previous_summary: "## Goal\nold"
    )

    user_text = provider.calls.first[:messages].last[:content].first[:text]

    assert_includes user_text, "<previous-summary>\n## Goal\nold\n</previous-summary>"
    assert_includes user_text, "incorporate into the existing summary"
  end

  def test_generate_summary_raises_summarization_failed_on_a_provider_error
    provider = StubProvider.new([error_response("rate limited")])

    error = assert_raises(Compaction::Error) do
      Compaction.generate_summary(
        provider, summary_model(max_output: 0),
        [Truffle::Message.user("hi")], reserve_tokens: 1000
      )
    end

    assert_equal :summarization_failed, error.kind
    assert_includes error.message, "Summarization failed: rate limited"
  end

  def test_generate_summary_raises_aborted_on_an_aborted_response
    provider = StubProvider.new([aborted_response])

    error = assert_raises(Compaction::Error) do
      Compaction.generate_summary(
        provider, summary_model(max_output: 0),
        [Truffle::Message.user("hi")], reserve_tokens: 1000
      )
    end

    assert_equal :aborted, error.kind
  end

  def test_generate_summary_does_not_call_the_provider_when_already_aborted
    provider = StubProvider.new([StubProvider.text("ok")])
    signal = Truffle::AbortSignal.new
    signal.abort

    error = assert_raises(Compaction::Error) do
      Compaction.generate_summary(
        provider, summary_model(max_output: 0),
        [Truffle::Message.user("hi")], reserve_tokens: 1000, signal: signal
      )
    end

    assert_equal :aborted, error.kind
    assert_empty provider.calls
  end
end
