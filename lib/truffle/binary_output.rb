# frozen_string_literal: true

module Truffle
  # Drops binary and control noise from captured shell output, the port of pi's
  # sanitizeBinaryOutput (agent/harness/utils/shell-output.ts). A command can emit
  # raw control bytes (a spinner's cursor moves, a hex dump, a stray NUL) that would
  # corrupt the transcript the model reads, so they are removed before the output is
  # shown. Tab, newline, and carriage return survive here; the bash pipeline removes
  # the carriage returns in a later step, the way pi does.
  module BinaryOutput
    # The C0 control characters worth keeping: tab, line feed, carriage return.
    PRESERVED_CONTROLS = [0x09, 0x0a, 0x0d].freeze

    module_function

    def sanitize(str)
      str.each_char.reject { |char| drop?(char.ord) }.join
    end

    # Drop the C0 controls other than tab/LF/CR and the Unicode interlinear
    # annotation format characters (U+FFF9 to U+FFFB); keep everything else, so DEL
    # and the C1 controls survive, matching pi's <= 0x1f cutoff exactly.
    def drop?(code)
      return false if PRESERVED_CONTROLS.include?(code)
      return true if code <= 0x1f

      code.between?(0xfff9, 0xfffb)
    end
  end
end
