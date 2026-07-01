# frozen_string_literal: true

require_relative "test_helper"

class ImageCaptureProvider < Truffle::Providers::Base
  attr_reader :calls, :name

  def initialize(name: "capture")
    super()
    @name = name
    @calls = []
  end

  def chat(messages:, tools: [], model: nil, **)
    calls << { messages: messages.dup, tools: tools, model: model }
    StubProvider.text("ok")
  end

  def chat_stream(messages:, tools: [], model: nil, signal: nil, **)
    calls << { messages: messages.dup, tools: tools, model: model, signal: signal }
    message = Truffle::Message.assistant(content: "ok")
    yield Truffle::StreamEvent.new(type: :start)
    yield Truffle::StreamEvent.new(type: :text_start, content_index: 0)
    yield Truffle::StreamEvent.new(type: :text_delta, content_index: 0, delta: "ok")
    yield Truffle::StreamEvent.new(type: :text_end, content_index: 0, content: "ok")
    yield Truffle::StreamEvent.new(type: :done, reason: Truffle::StopReason::STOP,
                                   message: message)
    Truffle::Response.new(message: message, stop_reason: Truffle::StopReason::STOP)
  end
end

class TestAgentImageDowngrade < Minitest::Test
  PLACEHOLDER = Truffle::MessageTransform::NON_VISION_USER_IMAGE_PLACEHOLDER

  def setup
    Truffle::ProviderRegistry.clear
  end

  def teardown
    Truffle::ProviderRegistry.clear
  end

  def test_buffered_turn_downgrades_images_for_a_text_only_model
    provider = ImageCaptureProvider.new
    agent = Truffle::Agent.new(provider: provider, model: model(input: %i[text]))

    agent.run("describe this", images: [image])

    sent = provider.calls.first.fetch(:messages).last

    assert_equal "text-only", provider.calls.first.fetch(:model)
    assert_equal ["describe this", PLACEHOLDER], sent.content.map(&:text)
    assert_equal %i[text image], agent.messages[0].content.map(&:type)
  end

  def test_streaming_turn_uses_the_same_image_downgrade
    provider = ImageCaptureProvider.new
    agent = Truffle::Agent.new(provider: provider, model: model(input: %i[text]))

    result = agent.run_stream("describe this", images: [image]) { nil }
    sent = provider.calls.first.fetch(:messages).last

    assert_equal "ok", result
    assert_equal ["describe this", PLACEHOLDER], sent.content.map(&:text)
    assert_equal %i[text image], agent.messages[0].content.map(&:type)
  end

  def test_vision_model_keeps_images
    provider = ImageCaptureProvider.new
    agent = Truffle::Agent.new(provider: provider, model: model(input: %i[text image]))

    agent.run("describe this", images: [image])

    assert_equal %i[text image], provider.calls.first.fetch(:messages).last.content.map(&:type)
  end

  def test_unknown_model_keeps_images_instead_of_guessing
    provider = ImageCaptureProvider.new
    agent = Truffle::Agent.new(provider: provider, model: "unknown-model")

    agent.run("describe this", images: [image])

    assert_equal %i[text image], provider.calls.first.fetch(:messages).last.content.map(&:type)
    assert_nil agent.model_spec
  end

  def test_registered_text_only_model_drives_the_agent_boundary
    Truffle.register_provider(
      "local",
      api: :openai_completions,
      base_url: "http://localhost:11434/v1",
      api_key: "test-key",
      models: [{ id: "registered-text-only", input: ["text"] }]
    )
    provider = ImageCaptureProvider.new(name: "local")
    agent = Truffle::Agent.new(provider: provider, model: "registered-text-only")

    agent.run("describe this", images: [image])

    assert_equal [:text], agent.model_spec.input
    assert_equal ["describe this", PLACEHOLDER],
                 provider.calls.first.fetch(:messages).last.content.map(&:text)
  end

  private

  def image
    Truffle::Content::Image.new(data: "Zm9v", mime_type: "image/png")
  end

  def model(input:)
    Truffle::Model.new(
      id: "text-only", name: "Text only", provider: :capture, api: :test,
      context_window: 10_000, max_output: 1000, input: input,
      cost: { input: 0, output: 0, cache_read: 0, cache_write: 0 }
    )
  end
end
