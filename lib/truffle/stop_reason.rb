# frozen_string_literal: true

module Truffle
  # Why a model turn stopped. Ported from pi's StopReason union in
  # packages/ai/src/types.ts: "stop" | "length" | "toolUse" | "error" | "aborted".
  #
  # The values are symbols so they read like Ruby; pi's camelCase "toolUse"
  # becomes :tool_use. A turn ends for one of these reasons:
  #
  #   :stop     - the model finished its answer on its own
  #   :length   - it hit the max-tokens ceiling mid-turn
  #   :tool_use - it paused to call one or more tools
  #   :error    - the provider or runtime failed
  #   :aborted  - it was cancelled before completing
  #
  # The canonical set lives here; mapping a provider's native finish reason onto
  # one of these is the provider's job (see Providers::OpenAI.map_stop_reason),
  # because every wire API spells its reasons differently.
  module StopReason
    STOP = :stop
    LENGTH = :length
    TOOL_USE = :tool_use
    ERROR = :error
    ABORTED = :aborted

    ALL = [STOP, LENGTH, TOOL_USE, ERROR, ABORTED].freeze

    def self.valid?(reason)
      ALL.include?(reason)
    end
  end
end
