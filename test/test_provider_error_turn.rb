# frozen_string_literal: true

require_relative "test_helper"

# A failed provider call must surface as a returned error turn, not an
# exception: a Response whose stop_reason is :error carrying the failure text.
# This is the contract the agent loop relies on to inspect a failure (end on it,
# or compact and retry on a context overflow). It mirrors pi, where a provider
# never throws out of a call; it returns a message with stopReason "error". The
# streaming paths already fold their failures this way through the accumulator's
# #fail, so these tests cover the non-streaming #chat path.
class TestProviderErrorTurn < Minitest::Test
  include Truffle

  # A Net::HTTP stand-in whose #request raises, to drive the transport-fault
  # path of #post without a network. It accepts the setters #post configures.
  class FailingHTTP
    def initialize(error) = @error = error
    def use_ssl=(_); end
    def open_timeout=(_); end
    def read_timeout=(_); end
    def request(_) = raise @error
  end

  class ResponseHTTP
    def initialize(response) = @response = response
    def use_ssl=(_); end
    def open_timeout=(_); end
    def read_timeout=(_); end
    def request(_) = @response
  end

  class FailedHTTPResponse
    attr_reader :code, :body

    def initialize(code:, body:, headers: {})
      @code = code
      @body = body
      @headers = headers
    end

    def [](name)
      @headers[name.downcase]
    end
  end

  def providers
    [
      Providers::Anthropic.new(api_key: "test-key"),
      Providers::OpenAI.new(api_key: "test-key"),
      Providers::Google.new(api_key: "test-key")
    ]
  end

  def chat(provider) = provider.chat(messages: [Message.user("hi")])

  # --- #chat folds a Providers::Error into an error turn --------------------

  def test_chat_returns_an_error_turn_instead_of_raising
    providers.each do |provider|
      boom = ->(*) { raise Providers::Error, "boom from #{provider.name}" }
      response = provider.stub(:post, boom) { chat(provider) }

      assert_equal StopReason::ERROR, response.stop_reason, provider.name
      assert_equal "boom from #{provider.name}", response.error_message, provider.name
      refute_predicate response, :tool_calls?, provider.name
      assert_empty response.message.content, provider.name
    end
  end

  def test_chat_carries_retry_after_from_provider_error
    provider = Providers::OpenAI.new(api_key: "test-key")
    error = Providers::Error.new("OpenAI 429: slow down", retry_after_ms: 1500)
    response = provider.stub(:post, ->(*) { raise error }) { chat(provider) }

    assert_equal 1500, response.retry_after_ms
  end

  def test_error_turn_usage_is_zero
    provider = Providers::Anthropic.new(api_key: "test-key")
    response = provider.stub(:post, ->(*) { raise Providers::Error, "nope" }) { chat(provider) }

    assert_equal 0, response.usage.total_tokens
  end

  # --- the error turn feeds overflow detection ------------------------------

  def test_an_overflow_error_turn_is_recognized_as_overflow
    provider = Providers::Anthropic.new(api_key: "test-key")
    overflow = "Anthropic 400: {\"error\":{\"message\":\"prompt is too long: 250000 tokens\"}}"
    response = provider.stub(:post, ->(*) { raise Providers::Error, overflow }) { chat(provider) }

    assert Overflow.context_overflow?(response)
  end

  def test_a_rate_limit_error_turn_is_not_overflow
    provider = Providers::OpenAI.new(api_key: "test-key")
    rate = "OpenAI 429: rate limit reached for requests"
    response = provider.stub(:post, ->(*) { raise Providers::Error, rate }) { chat(provider) }

    assert_equal StopReason::ERROR, response.stop_reason
    refute Overflow.context_overflow?(response)
  end

  # --- #post folds a transport fault into a Providers::Error ----------------

  def test_post_converts_a_connection_failure_into_a_provider_error
    provider = Providers::Anthropic.new(api_key: "test-key")
    failing = FailingHTTP.new(Errno::ECONNREFUSED.new("Connection refused"))

    error = Net::HTTP.stub(:new, failing) do
      assert_raises(Providers::Error) { provider.send(:post, "/v1/messages", {}) }
    end

    assert_includes error.message, "Anthropic request failed"
    assert_includes error.message, "Errno::ECONNREFUSED"
  end

  def test_post_converts_a_read_timeout_into_a_provider_error
    provider = Providers::OpenAI.new(api_key: "test-key")
    failing = FailingHTTP.new(Net::ReadTimeout.new)

    error = Net::HTTP.stub(:new, failing) do
      assert_raises(Providers::Error) { provider.send(:post, "/chat/completions", {}) }
    end

    assert_includes error.message, "OpenAI request failed"
  end

  def test_post_parses_retry_after_ms_header
    provider = Providers::OpenAI.new(api_key: "test-key")
    response = FailedHTTPResponse.new(
      code: "429",
      body: "rate limit",
      headers: { "retry-after-ms" => "1500" }
    )

    error = Net::HTTP.stub(:new, ResponseHTTP.new(response)) do
      assert_raises(Providers::Error) { provider.send(:post, "/chat/completions", {}) }
    end

    assert_equal 1500, error.retry_after_ms
  end

  def test_post_parses_retry_after_seconds_header
    provider = Providers::Anthropic.new(api_key: "test-key")
    response = FailedHTTPResponse.new(
      code: "429",
      body: "rate limit",
      headers: { "retry-after" => "2" }
    )

    error = Net::HTTP.stub(:new, ResponseHTTP.new(response)) do
      assert_raises(Providers::Error) { provider.send(:post, "/v1/messages", {}) }
    end

    assert_equal 2000, error.retry_after_ms
  end

  def test_post_parses_retry_after_http_date_header
    provider = Providers::Google.new(api_key: "test-key")
    retry_at = (Time.now + 60).httpdate
    response = FailedHTTPResponse.new(
      code: "429",
      body: "rate limit",
      headers: { "retry-after" => retry_at }
    )

    error = Net::HTTP.stub(:new, ResponseHTTP.new(response)) do
      assert_raises(Providers::Error) { provider.send(:post, "/models/gemini:test", {}) }
    end

    assert_operator error.retry_after_ms, :>, 0
    assert_operator error.retry_after_ms, :<=, 60_000
  end

  # --- a transport fault folds all the way to an error turn through #chat ----

  def test_chat_folds_a_transport_fault_into_an_error_turn
    provider = Providers::Google.new(api_key: "test-key")
    failing = FailingHTTP.new(SocketError.new("getaddrinfo: Name or service not known"))

    response = Net::HTTP.stub(:new, failing) { chat(provider) }

    assert_equal StopReason::ERROR, response.stop_reason
    assert_includes response.error_message, "Google request failed"
  end
end
