# frozen_string_literal: true

module Truffle
  module CLI
    # The thin entry point behind the `truffle` executable. It parses argv,
    # surfaces the parser's diagnostics, and acts on the terminal flags the
    # harness supports today: `--version`, `--help`, and `--list-models`. This
    # is the Ruby counterpart of the top of pi's `main.ts` dispatcher, narrowed
    # to the slices that exist. The interactive REPL and `--export` are later
    # slices of roadmap item 19, so any other invocation reports that and exits.
    #
    # `run` takes injectable out/err streams and RETURNS an exit status rather
    # than calling `exit`, so the whole dispatch is testable offline with StringIO
    # and the executable stays a one-line caller.

    # Exit status when the only instruction is a flag the binary cannot act on
    # yet (the interactive REPL is a later slice).
    EXIT_NOT_IMPLEMENTED = 2

    module_function

    def run(argv, out: $stdout, err: $stderr)
      args = parse_args(argv)
      report_diagnostics(args.diagnostics, err)
      return 1 if args.diagnostics.any? { |diagnostic| diagnostic[:type] == :error }

      if args.version
        out.puts version_text
        return 0
      end

      if args.help
        out.puts help_text(color: color?(out))
        return 0
      end

      if args.list_models
        search = args.list_models == true ? nil : args.list_models
        out.print models_text(search: search)
        return 0
      end

      err.puts "#{APP_NAME}: interactive mode is not implemented yet"
      EXIT_NOT_IMPLEMENTED
    end

    # Print each diagnostic on its own line, mirroring pi's red Error / yellow
    # Warning prefixes without the color (the binary's own color is gated on a
    # tty below, and plain text keeps these lines greppable in logs and tests).
    def report_diagnostics(diagnostics, err)
      diagnostics.each do |diagnostic|
        label = diagnostic[:type] == :error ? "Error" : "Warning"
        err.puts "#{label}: #{diagnostic[:message]}"
      end
    end

    # Color the help only when the output is an interactive terminal, the way
    # pi's chalk auto-disables when stdout is not a tty.
    def color?(out)
      out.respond_to?(:tty?) && out.tty?
    end

    private_class_method :report_diagnostics, :color?
  end
end
