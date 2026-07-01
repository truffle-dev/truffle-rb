# frozen_string_literal: true

module Truffle
  # Resume-time check that a session's recorded working directory still exists.
  # A session stores the cwd it was created in; if that directory is later moved
  # or deleted, resuming into it would run tools against a path that is gone. A
  # resume flow uses this to warn and offer the current directory as a fallback
  # instead of failing deep inside a tool call. A faithful port of pi's
  # packages/coding-agent/src/core/session-cwd.ts.
  #
  # pi passes a SessionCwdSource duck type with getCwd() / getSessionFile()
  # getters; the Ruby port takes those two values as keyword arguments, so a
  # Session, a Session::Summary, or a future resume CLI can supply them without
  # implementing an interface.
  module SessionCwd
    # A session whose recorded cwd is missing from disk. `session_file` is the
    # path the session was read from; `fallback_cwd` is the directory to resume
    # in instead (normally the current working directory).
    Issue = Struct.new(:session_file, :session_cwd, :fallback_cwd, keyword_init: true)

    module_function

    # An Issue when the session has a file and a recorded cwd that is present in
    # the header but missing from disk, else nil. A session with no file (never
    # written), a blank recorded cwd, or a cwd that still exists is fine to
    # resume, matching pi's getMissingSessionCwdIssue: no file short-circuits
    # first, then a blank-or-existing cwd.
    def missing_issue(session_cwd:, fallback_cwd:, session_file: nil)
      return nil if session_file.nil? || session_file.empty?
      return nil if session_cwd.nil? || session_cwd.empty?
      return nil if File.exist?(session_cwd)

      Issue.new(session_file: session_file, session_cwd: session_cwd, fallback_cwd: fallback_cwd)
    end

    # The multi-line error string for a missing session cwd. The session-file
    # line is omitted when the issue carries no file, matching pi.
    def format_error(issue)
      file_line = issue.session_file ? "\nSession file: #{issue.session_file}" : ""
      "Stored session working directory does not exist: #{issue.session_cwd}#{file_line}\n" \
        "Current working directory: #{issue.fallback_cwd}"
    end

    # The short prompt string offering to continue in the current cwd.
    def format_prompt(issue)
      "cwd from session file does not exist\n#{issue.session_cwd}\n\n" \
        "continue in current cwd\n#{issue.fallback_cwd}"
    end

    # Raise MissingError when the session's recorded cwd is missing, else return
    # nil. Ports pi's assertSessionCwdExists.
    def assert_exists(session_cwd:, fallback_cwd:, session_file: nil)
      issue = missing_issue(session_cwd: session_cwd, fallback_cwd: fallback_cwd,
                            session_file: session_file)
      raise MissingError, issue if issue

      nil
    end

    # Raised when a session's recorded working directory no longer exists. Carries
    # the Issue so a caller can offer the fallback without reparsing the message.
    class MissingError < StandardError
      attr_reader :issue

      def initialize(issue)
        @issue = issue
        super(SessionCwd.format_error(issue))
      end
    end
  end
end
