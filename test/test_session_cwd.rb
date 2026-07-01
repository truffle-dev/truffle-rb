# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class TestSessionCwd < Minitest::Test
  include Truffle

  def test_no_issue_when_the_session_has_no_file
    # A session that was never written to disk cannot have a stale cwd to warn
    # about, so a missing directory with no file is not an issue.
    assert_nil SessionCwd.missing_issue(session_cwd: "/nope/gone", fallback_cwd: "/here",
                                        session_file: nil)
    assert_nil SessionCwd.missing_issue(session_cwd: "/nope/gone", fallback_cwd: "/here",
                                        session_file: "")
  end

  def test_no_issue_when_the_recorded_cwd_is_blank
    assert_nil SessionCwd.missing_issue(session_cwd: nil, fallback_cwd: "/here",
                                        session_file: "/s.jsonl")
    assert_nil SessionCwd.missing_issue(session_cwd: "", fallback_cwd: "/here",
                                        session_file: "/s.jsonl")
  end

  def test_no_issue_when_the_recorded_cwd_still_exists
    Dir.mktmpdir do |dir|
      assert_nil SessionCwd.missing_issue(session_cwd: dir, fallback_cwd: "/here",
                                          session_file: "/s.jsonl")
    end
  end

  def test_issue_when_the_recorded_cwd_is_missing
    Dir.mktmpdir do |dir|
      gone = File.join(dir, "moved-away")
      issue = SessionCwd.missing_issue(session_cwd: gone, fallback_cwd: dir,
                                       session_file: "/agent/s.jsonl")

      refute_nil issue
      assert_equal gone, issue.session_cwd
      assert_equal dir, issue.fallback_cwd
      assert_equal "/agent/s.jsonl", issue.session_file
    end
  end

  def test_format_error_includes_the_session_file_line
    issue = SessionCwd::Issue.new(session_file: "/a/s.jsonl", session_cwd: "/gone",
                                  fallback_cwd: "/here")

    assert_equal "Stored session working directory does not exist: /gone\n" \
                 "Session file: /a/s.jsonl\n" \
                 "Current working directory: /here",
                 SessionCwd.format_error(issue)
  end

  def test_format_error_omits_the_session_file_line_when_absent
    issue = SessionCwd::Issue.new(session_file: nil, session_cwd: "/gone",
                                  fallback_cwd: "/here")

    assert_equal "Stored session working directory does not exist: /gone\n" \
                 "Current working directory: /here",
                 SessionCwd.format_error(issue)
  end

  def test_format_prompt_offers_the_fallback
    issue = SessionCwd::Issue.new(session_file: "/a/s.jsonl", session_cwd: "/gone",
                                  fallback_cwd: "/here")

    assert_equal "cwd from session file does not exist\n/gone\n\n" \
                 "continue in current cwd\n/here",
                 SessionCwd.format_prompt(issue)
  end

  def test_assert_exists_raises_with_the_issue_when_cwd_is_missing
    Dir.mktmpdir do |dir|
      gone = File.join(dir, "moved-away")
      error = assert_raises(SessionCwd::MissingError) do
        SessionCwd.assert_exists(session_cwd: gone, fallback_cwd: dir,
                                 session_file: "/agent/s.jsonl")
      end

      assert_equal gone, error.issue.session_cwd
      assert_equal SessionCwd.format_error(error.issue), error.message
    end
  end

  def test_assert_exists_returns_nil_when_cwd_is_present
    Dir.mktmpdir do |dir|
      assert_nil SessionCwd.assert_exists(session_cwd: dir, fallback_cwd: "/here",
                                          session_file: "/s.jsonl")
    end
  end
end
