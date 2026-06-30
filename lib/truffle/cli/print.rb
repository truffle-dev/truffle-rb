# frozen_string_literal: true

module Truffle
  module CLI
    # The output half of pi's print mode (single-shot `truffle -p "..."`): given
    # the final assistant turn of a run, write its text to stdout, or surface an
    # error or aborted turn on stderr with a nonzero exit. This is the rendering
    # primitive the eventual `--print` dispatch calls once it has driven the
    # agent; keeping it pure over a Response is what lets it test offline without
    # a provider.
    #
    # Faithful to the text branch of `runPrintMode` in pi's
    # `modes/print-mode.ts`: an error or aborted stop reason prints
    # `errorMessage || "Request <reason>"` to stderr and exits 1; otherwise each
    # text content block is written on its own line, with thinking and tool-call
    # blocks skipped the way pi only emits `content.type === "text"`. A run with
    # no final assistant response prints nothing and exits 0, the analog of pi's
    # `lastMessage?.role === "assistant"` guard.

    # Stop reasons that make a single-shot run a failure: nothing usable was
    # produced for the caller, so print mode reports the reason and exits nonzero.
    PRINT_FAILURE_STOP_REASONS = [StopReason::ERROR, StopReason::ABORTED].freeze

    module_function

    # Render the final assistant `response` of a single-shot run, returning the
    # process exit status. Streams are injectable so the dispatch is testable
    # offline. A nil response (no assistant turn was produced) is a no-op success.
    def render_print_text(response, out: $stdout, err: $stderr)
      return 0 if response.nil?

      if PRINT_FAILURE_STOP_REASONS.include?(response.stop_reason)
        message = response.error_message || "Request #{response.stop_reason}"
        err.write("#{message}\n")
        return 1
      end

      response.message.content.grep(Content::Text).each do |block|
        out.write("#{block.text}\n")
      end
      0
    end
  end
end
