# frozen_string_literal: true

require_relative "stop_reason"

module Truffle
  # Detecting context overflow: a turn that failed (or silently degraded) because
  # the prompt plus history exceeded the model's context window. This is distinct
  # from an output-length limit. The agent loop uses it to decide whether a failed
  # turn should trigger an emergency compaction and retry rather than surface as a
  # plain error. A faithful port of pi's packages/ai/src/utils/overflow.ts.
  #
  # Three signals, because providers report overflow three different ways:
  #   1. An error turn whose message matches a known overflow phrase (most
  #      providers), excluding phrases that look like overflow but are really
  #      rate-limit or throttling errors.
  #   2. A successful turn whose reported input already exceeds the window (z.ai
  #      accepts the oversized request instead of erroring).
  #   3. A length-stopped turn that produced no output with input filling the
  #      window (Xiaomi MiMo truncates the input to fit, leaving no room to
  #      generate).
  # Cases 2 and 3 need the window, so they only fire when context_window is given.
  module Overflow
    # Error phrases that mean the input exceeded the context window. Each entry is
    # the wording one provider (or proxy) uses; the provider is named so a future
    # reader knows why the pattern is here and can add the next one from a real
    # error string rather than a guess. Ported verbatim from pi's OVERFLOW_PATTERNS.
    OVERFLOW_PATTERNS = [
      /prompt is too long/i,                    # Anthropic token overflow
      /request_too_large/i,                     # Anthropic request byte-size overflow (HTTP 413)
      /input is too long for requested model/i, # Amazon Bedrock
      /exceeds the context window/i,            # OpenAI (Completions & Responses API)
      # OpenAI-compatible proxies (LiteLLM)
      /exceeds (?:the )?(?:model'?s )?maximum context length(?: of [\d,]+ tokens?|\s*\([\d,]+\))/i,
      /input token count.*exceeds the maximum/i, # Google (Gemini)
      /maximum prompt length is \d+/i,           # xAI (Grok)
      /reduce the length of the messages/i,      # Groq
      /maximum context length is \d+ tokens/i,   # OpenRouter (most backends)
      /exceeds (?:the )?maximum allowed input length of [\d,]+ tokens?/i, # OpenRouter/Poolside
      # Together AI
      /input \(\d+ tokens\) is longer than the model'?s context length \(\d+ tokens\)/i,
      /exceeds the limit of \d+/i,           # GitHub Copilot
      /exceeds the available context size/i, # llama.cpp server
      /greater than the context length/i,    # LM Studio
      /context window exceeds limit/i,       # MiniMax
      /exceeded model token limit/i,         # Kimi For Coding
      /too large for model with \d+ maximum context length/i, # Mistral
      /model_context_window_exceeded/i,                       # z.ai non-standard reason
      /prompt too long; exceeded (?:max )?context length/i,   # Ollama explicit overflow error
      /context[_ ]length[_ ]exceeded/i, # Generic fallback
      /too many tokens/i,               # Generic fallback
      /token limit exceeded/i,          # Generic fallback
      /^4(?:00|13)\s*(?:status code)?\s*\(no body\)/i # Cerebras: 400/413 with no body
    ].freeze

    # Phrases that match an overflow pattern but are really something else (a
    # rate limit, a throttle, a transient server error). A message matching one of
    # these is never treated as overflow even if it also matches an overflow
    # pattern. Ported from pi's NON_OVERFLOW_PATTERNS.
    NON_OVERFLOW_PATTERNS = [
      /^(Throttling error|Service unavailable):/i, # AWS Bedrock human-readable prefixes
      /rate limit/i,                               # Generic rate limiting
      /too many requests/i                         # Generic HTTP 429 style
    ].freeze

    # The fraction of the window a length-stopped, zero-output turn must fill to
    # count as overflow. pi uses 0.99: a server that truncates the input to fit
    # leaves the window all but full.
    LENGTH_STOP_FILL_RATIO = 0.99

    module_function

    # Whether a provider response represents a context overflow. response carries
    # the turn's stop reason, error text, and usage (it is this port's analog of
    # pi's AssistantMessage, which bundles the same fields). context_window, when
    # given, enables the two window-relative signals (silent overflow and the
    # length-stop case); without it only the error-phrase signal applies.
    def context_overflow?(response, context_window: nil)
      return true if error_overflow?(response)

      usage = response.usage
      input_tokens = usage.input + usage.cache_read

      return false unless context_window

      silent_overflow?(response, input_tokens, context_window) ||
        length_stop_overflow?(response, usage, input_tokens, context_window)
    end

    # The overflow patterns, copied so a caller (or a test) cannot mutate the
    # frozen source list. Mirrors pi's getOverflowPatterns.
    def patterns
      OVERFLOW_PATTERNS.dup
    end

    # Case 1: an error turn whose message reads as an overflow, and not as a
    # throttle or rate limit.
    def error_overflow?(response)
      return false unless response.stop_reason == StopReason::ERROR

      message = response.error_message
      return false if message.nil? || message.empty?
      return false if NON_OVERFLOW_PATTERNS.any? { |pattern| pattern.match?(message) }

      OVERFLOW_PATTERNS.any? { |pattern| pattern.match?(message) }
    end
    private_class_method :error_overflow?

    # Case 2: a successful turn whose reported input already exceeds the window
    # (z.ai accepts the oversized request rather than erroring).
    def silent_overflow?(response, input_tokens, context_window)
      response.stop_reason == StopReason::STOP && input_tokens > context_window
    end
    private_class_method :silent_overflow?

    # Case 3: a length-stopped turn that generated nothing with the input filling
    # the window (Xiaomi MiMo truncates the input to fit, leaving no room to
    # generate).
    def length_stop_overflow?(response, usage, input_tokens, context_window)
      response.stop_reason == StopReason::LENGTH && usage.output.zero? &&
        input_tokens >= context_window * LENGTH_STOP_FILL_RATIO
    end
    private_class_method :length_stop_overflow?
  end
end
