# frozen_string_literal: true

require "open3"
require "tmpdir"
require "securerandom"
require_relative "truncate"
require_relative "../ansi"
require_relative "../binary_output"

module Truffle
  module Tools
    BASH_DESCRIPTION =
      "Execute a bash command in the current working directory. Returns stdout " \
      "and stderr. Output is truncated to last #{Truncate::DEFAULT_MAX_LINES} lines " \
      "or #{Truncate::DEFAULT_MAX_BYTES / 1024}KB (whichever is hit first). If " \
      "truncated, full output is saved to a temp file. Optionally provide a " \
      "timeout in seconds."
      .freeze

    # Build pi's `bash` tool, bound to a working directory. The command runs under
    # bash with stdout and stderr combined, in command order. Output is tail
    # truncated (the end, where errors and results live); when truncated the full
    # output is written to a temp file and the returned text points at it. A
    # nonzero exit, or a timeout, raises with the captured output plus a status
    # line, which the agent loop reports back to the model, matching pi's throw.
    def self.bash(cwd: Dir.pwd, shell: Bash::DEFAULT_SHELL)
      Tool.define("bash", BASH_DESCRIPTION, execution_mode: :sequential) do
        param :command, :string, "Bash command to execute", required: true
        param :timeout, :number, "Timeout in seconds (optional, no default timeout)"
        run do |command:, timeout: nil|
          Bash.run(command: command, cwd: cwd, timeout: timeout, shell: shell)
        end
      end
    end

    # The bash engine, a port of bash.ts's execute path (the TUI rendering in
    # bash.ts is out of scope). It lives in its own module so its private helpers
    # (format, capture, kill) do not collide with the other tools' flat helpers,
    # the way Truncate and Path are also nested modules. The streaming,
    # memory-bounded OutputAccumulator is not ported: this buffers the full output,
    # which leaves the observable result (returned tail, truncation notice, temp
    # file) identical and only differs for outputs large enough to matter for
    # memory, a later slice.
    module Bash
      # The shell the bash tool runs commands under. The tool is named "bash" and
      # its description promises bash, so resolve a real bash before falling back
      # to PATH lookup.
      DEFAULT_SHELL = ["/bin/bash", "/usr/bin/bash"].find { |p| File.executable?(p) } || "bash"

      module_function

      def run(command:, cwd:, timeout: nil, shell: DEFAULT_SHELL)
        unless File.directory?(cwd)
          raise "Working directory does not exist: #{cwd}\nCannot execute bash commands."
        end

        raw, status, timed_out = capture(command, cwd, timeout, shell)
        # pi cleans each captured chunk through stripAnsi, then sanitizeBinaryOutput,
        # then drops carriage returns (bash-executor.ts). The cleaned text is what
        # feeds both the returned tail and the full-output temp file. We buffer the
        # whole output rather than stream it, so clean the joined string once here;
        # for well-behaved output that is identical, and it correctly handles a
        # multibyte character split across two reads, which per-chunk cleaning cannot.
        decoded = raw.dup.force_encoding("UTF-8").scrub
        cleaned = BinaryOutput.sanitize(Ansi.strip(decoded)).delete("\r")
        truncation = Truncate.tail(cleaned)
        full_output_path = truncation.truncated ? write_full_output(cleaned) : nil
        last_line_bytes = partial_line_bytes(truncation, cleaned)

        if timed_out
          text = format_output(truncation, full_output_path, last_line_bytes, "")
          raise append_status(text, "Command timed out after #{timeout} seconds")
        end

        text = format_output(truncation, full_output_path, last_line_bytes, "(no output)")

        # A command killed by a signal (OOM killer, an external SIGKILL) is not a
        # success, even though it produced partial output. pi cannot see this: its
        # waitForChildProcess keeps only Node's exit-code argument and drops the
        # signal, so a signaled child reports a null code and slips through as
        # clean. Ruby's Process::Status does carry the signal, so surface it with
        # the shell's 128 + signal convention. The timeout branch above already
        # returned, so this only fires for signals we did not send ourselves.
        if status&.signaled?
          signal = status.termsig
          status_line = "Command terminated by signal #{signal} (exit code #{128 + signal})"
          raise append_status(text, status_line)
        end

        code = status&.exitstatus
        raise append_status(text, "Command exited with code #{code}") if !code.nil? && code != 0

        text
      end

      # Run the command, returning [raw_bytes, Process::Status, timed_out]. The
      # child leads its own process group so a timeout kills the whole tree (the
      # pid limit in this container is small; leaking descendants is not an
      # option). Output is read in a thread so a forced pipe close can release a
      # read that a detached descendant would otherwise hold open.
      def capture(command, cwd, timeout, shell)
        chunks = []
        timed_out = false
        status = nil

        Open3.popen2e(shell, "-c", command, chdir: cwd, pgroup: true) do |stdin, out, wait_thr|
          stdin.close
          out.binmode
          reader = Thread.new do
            loop { chunks << out.readpartial(65_536) }
          rescue IOError # EOFError is a subclass; a forced close raises IOError.
            nil
          end

          if timeout&.positive? && !wait_thr.join(timeout)
            timed_out = true
            kill_process_tree(wait_thr.pid)
          end
          status = wait_thr.value

          unless reader.join(0.2)
            out.close
            reader.join
          end
        end

        [chunks.join, status, timed_out]
      end

      # The byte length of the final line, needed only for the partial-last-line
      # truncation notice; zero otherwise.
      def partial_line_bytes(truncation, decoded)
        return 0 unless truncation.last_line_partial

        Truncate.split_for_counting(decoded).last&.bytesize || 0
      end

      # Signal the child's whole process group, then hard-kill any stragglers a
      # moment later. Negative pid targets the group, since the child leads it.
      def kill_process_tree(pid)
        Process.kill("TERM", -pid)
        sleep 0.1
        Process.kill("KILL", -pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      # Write the full (cleaned, untruncated) output to a temp file and return its
      # path, the way pi preserves output that did not fit the tail. pi writes the
      # sanitized text to this file, not the raw bytes, so it holds the same cleaned
      # output the tail was taken from.
      def write_full_output(cleaned)
        path = File.join(Dir.tmpdir, "truffle-bash-#{SecureRandom.hex(8)}.log")
        File.binwrite(path, cleaned)
        path
      end

      # Build the text the model sees: the (possibly tail-truncated) output, then
      # a bracketed notice when truncated. The byte-limit notice reports pi's
      # default 50KB constant, not the applied limit, matching bash.ts exactly.
      def format_output(truncation, full_output_path, last_line_bytes, empty_text)
        text = truncation.content.empty? ? empty_text : truncation.content
        return text unless truncation.truncated

        "#{text}\n\n#{truncation_notice(truncation, full_output_path, last_line_bytes)}"
      end

      def truncation_notice(truncation, full_output_path, last_line_bytes)
        end_line = truncation.total_lines
        start_line = truncation.total_lines - truncation.output_lines + 1
        if truncation.last_line_partial
          "[Showing last #{Truncate.format_size(truncation.output_bytes)} of line #{end_line} " \
            "(line is #{Truncate.format_size(last_line_bytes)}). Full output: #{full_output_path}]"
        elsif truncation.truncated_by == "lines"
          "[Showing lines #{start_line}-#{end_line} of #{truncation.total_lines}. " \
            "Full output: #{full_output_path}]"
        else
          limit = Truncate.format_size(Truncate::DEFAULT_MAX_BYTES)
          "[Showing lines #{start_line}-#{end_line} of #{truncation.total_lines} " \
            "(#{limit} limit). Full output: #{full_output_path}]"
        end
      end

      # pi's appendStatus: a status line after the output, separated by a blank
      # line, or alone when there is no output.
      def append_status(text, status)
        text.empty? ? status : "#{text}\n\n#{status}"
      end
    end
  end
end
