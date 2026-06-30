# frozen_string_literal: true

require "test_helper"
require "stringio"

# A stand-in for the agent a `--print` run drives, with no provider and no
# network. It records the prompts it is sent and replays a scripted `:agent_end`
# payload after each run, so the dispatch's prompt assembly and final-response
# capture can be exercised offline. Later runs replay later payloads (clamped to
# the last), which is how the "last assistant turn wins" rule gets proven.
class PrintStubAgent
  attr_reader :prompts

  def initialize(payloads)
    @payloads = payloads
    @listeners = Hash.new { |h, k| h[k] = [] }
    @all_listeners = []
    @prompts = []
    @run = 0
  end

  def on(event = nil, &block)
    if event
      @listeners[event] << block
    else
      @all_listeners << block
    end
    self
  end

  def run(prompt)
    @prompts << prompt
    emit(:agent_start, input: prompt)
    payload = @payloads[@run] || @payloads.last
    @run += 1
    emit(:agent_end, payload) if payload
    ""
  end

  private

  def emit(event, payload)
    @listeners[event].each { |listener| listener.call(payload) }
    @all_listeners.each { |listener| listener.call(event, payload) }
  end
end

# An input stream that claims to be a terminal. `piped_stdin` must skip it
# without reading, so a `read` here returns content the dispatch should never
# splice into a prompt.
class FakeTTYInput
  def tty?
    true
  end

  def read
    "LEAK"
  end
end

# Tests for the `truffle` binary entry point (Truffle::CLI.run): the thin
# dispatcher that parses argv, surfaces diagnostics, and acts on the terminal
# flags the harness supports today.
class TestCLIRunner < Minitest::Test
  def run_cli(argv)
    out = StringIO.new
    err = StringIO.new
    status = Truffle::CLI.run(argv, out: out, err: err)
    [status, out.string, err.string]
  end

  # Drive a `--print` dispatch offline: an empty stdin unless one is given, and
  # an injected agent unless the test wants the real builder (to exercise the
  # unresolvable-model path).
  def run_print_cli(argv, input: StringIO.new(""), agent: nil)
    out = StringIO.new
    err = StringIO.new
    builder = agent && ->(_args) { agent }
    status = Truffle::CLI.run(argv, out: out, err: err, input: input, agent_builder: builder)
    [status, out.string, err.string]
  end

  # An :agent_end payload whose last message is an assistant turn of plain text.
  def assistant_payload(text, stop_reason: Truffle::StopReason::STOP, error_message: nil)
    message = Truffle::Message.assistant(content: text)
    { output: text, messages: [message], stop_reason: stop_reason, error_message: error_message }
  end

  def test_version_flag_prints_version_text_and_exits_zero
    status, out, err = run_cli(["--version"])

    assert_equal 0, status
    assert_equal "#{Truffle::CLI.version_text}\n", out
    assert_empty err
  end

  def test_help_flag_prints_help_and_exits_zero
    status, out, err = run_cli(["--help"])

    assert_equal 0, status
    assert_includes out, "truffle - AI coding assistant"
    assert_includes out, "Options:"
    assert_empty err
  end

  def test_list_models_prints_the_builtin_catalog_and_exits_zero
    status, out, err = run_cli(["--list-models"])

    assert_equal 0, status
    assert_includes out, "provider"
    assert_includes out, "gpt-4o-mini"
    assert_includes out, "claude-haiku-4-5"
    assert_empty err
  end

  def test_list_models_accepts_a_search_pattern
    status, out, err = run_cli(["--list-models", "sonnet"])

    assert_equal 0, status
    assert_includes out, "claude-sonnet-4-5"
    refute_includes out, "gpt-4o-mini"
    assert_empty err
  end

  def test_help_to_a_non_tty_stream_has_no_ansi_escapes
    _status, out, = run_cli(["-h"])

    refute_includes out, "\e["
  end

  def test_unknown_short_flag_reports_an_error_and_exits_one
    status, out, err = run_cli(["-z"])

    assert_equal 1, status
    assert_includes err, "Error: Unknown option: -z"
    assert_empty out
  end

  def test_a_warning_diagnostic_does_not_force_a_nonzero_exit_by_itself
    # --thinking with an invalid level warns but does not error, so the run
    # falls through to the not-yet-implemented interactive path.
    status, _out, err = run_cli(["--thinking", "bogus"])

    assert_includes err, "Warning:"
    refute_includes err, "Error:"
    assert_equal Truffle::CLI::EXIT_NOT_IMPLEMENTED, status
  end

  def test_an_error_short_circuits_before_version_is_printed
    status, out, err = run_cli(["-z", "--version"])

    assert_equal 1, status
    assert_includes err, "Error: Unknown option: -z"
    refute_includes out, Truffle::VERSION
  end

  def test_version_takes_precedence_over_help
    status, out, = run_cli(["--help", "--version"])

    assert_equal 0, status
    assert_equal "#{Truffle::CLI.version_text}\n", out
    refute_includes out, "Options:"
  end

  def test_version_takes_precedence_over_list_models
    status, out, = run_cli(["--list-models", "--version"])

    assert_equal 0, status
    assert_equal "#{Truffle::CLI.version_text}\n", out
    refute_includes out, "provider"
  end

  def test_no_actionable_flag_reports_the_unimplemented_repl
    status, out, err = run_cli([])

    assert_equal Truffle::CLI::EXIT_NOT_IMPLEMENTED, status
    assert_includes err, "truffle: interactive mode is not implemented yet"
    assert_empty out
  end

  # ---- --print single-shot dispatch ----

  def test_print_renders_the_final_assistant_text
    agent = PrintStubAgent.new([assistant_payload("the answer")])

    status, out, err = run_print_cli(["-p", "ask"], agent: agent)

    assert_equal 0, status
    assert_equal "the answer\n", out
    assert_empty err
    assert_equal ["ask"], agent.prompts
  end

  def test_print_surfaces_an_error_stop_on_stderr_and_exits_one
    payload = assistant_payload("", stop_reason: Truffle::StopReason::ERROR,
                                    error_message: "boom")
    agent = PrintStubAgent.new([payload])

    status, out, err = run_print_cli(["-p", "ask"], agent: agent)

    assert_equal 1, status
    assert_equal "boom\n", err
    assert_empty out
  end

  def test_print_renders_nothing_when_the_last_message_is_not_an_assistant_turn
    # A run that ended on a tool result (no assistant turn after it) renders
    # nothing, even on an error stop. The role guard is what skips it; without
    # it the error stop would be surfaced on stderr with exit 1.
    tool = Truffle::Message.tool(content: "result", tool_call_id: "c1", name: "read")
    payload = { messages: [tool], stop_reason: Truffle::StopReason::ERROR,
                error_message: "midtool" }
    agent = PrintStubAgent.new([payload])

    status, out, err = run_print_cli(["-p", "ask"], agent: agent)

    assert_equal 0, status
    assert_empty out
    assert_empty err
  end

  def test_print_joins_piped_stdin_with_the_first_message
    agent = PrintStubAgent.new([assistant_payload("ok")])

    status, = run_print_cli(["-p", "do it"], input: StringIO.new("ctx\n"), agent: agent)

    assert_equal 0, status
    assert_equal ["ctx\ndo it"], agent.prompts
  end

  def test_print_sends_remaining_messages_as_their_own_prompts_last_turn_wins
    agent = PrintStubAgent.new([assistant_payload("first reply"),
                                assistant_payload("second reply")])

    status, out, = run_print_cli(["-p", "one", "two"], agent: agent)

    assert_equal 0, status
    assert_equal %w[one two], agent.prompts
    assert_equal "second reply\n", out
  end

  def test_print_json_mode_writes_agent_events_as_json_lines
    agent = PrintStubAgent.new([assistant_payload("the answer")])

    status, out, err = run_print_cli(["-p", "ask", "--mode", "json"], agent: agent)
    events = out.lines.map { |line| JSON.parse(line) }

    assert_equal 0, status
    assert_empty err
    types = events.map { |event| event["type"] }

    assert_equal %w[agent_start agent_end], types
    assert_equal "ask", events.first["input"]
    assert_equal "the answer", events.last["output"]
    assert_equal "assistant", events.last["messages"].last["role"]
    assert_equal "stop", events.last["stop_reason"]
    refute_includes events.last, "error_message"
  end

  def test_json_mode_without_print_also_runs_single_shot_json_output
    agent = PrintStubAgent.new([assistant_payload("the answer")])

    status, out, err = run_print_cli(["--mode", "json", "ask"], agent: agent)
    events = out.lines.map { |line| JSON.parse(line) }
    types = events.map { |event| event["type"] }

    assert_equal 0, status
    assert_empty err
    assert_equal ["ask"], agent.prompts
    assert_equal %w[agent_start agent_end], types
  end

  def test_rpc_mode_reports_not_implemented_without_building_a_print_agent
    out = StringIO.new
    err = StringIO.new
    built = false

    status = Truffle::CLI.run(
      ["--print", "--mode", "rpc", "ask"],
      out: out,
      err: err,
      agent_builder: ->(_args) { built = true }
    )

    assert_equal Truffle::CLI::EXIT_NOT_IMPLEMENTED, status
    assert_equal "truffle: rpc mode is not implemented yet\n", err.string
    assert_empty out.string
    refute built
  end

  def test_print_does_not_read_an_interactive_stdin
    agent = PrintStubAgent.new([assistant_payload("ok")])

    status, = run_print_cli(["-p", "ask"], input: FakeTTYInput.new, agent: agent)

    assert_equal 0, status
    assert_equal ["ask"], agent.prompts
  end

  def test_print_with_no_input_at_all_sends_no_prompts
    agent = PrintStubAgent.new([assistant_payload("unused")])

    status, out, err = run_print_cli(["-p"], agent: agent)

    assert_equal 0, status
    assert_empty agent.prompts
    assert_empty out
    assert_empty err
  end

  def test_print_with_an_unresolvable_model_errors_on_stderr_and_exits_one
    status, out, err = run_print_cli(["-p", "ask"])

    assert_equal 1, status
    assert_includes err, "pass provider:"
    assert_empty out
  end

  def test_print_tools_default_to_the_full_builtin_set
    args = Truffle::CLI.parse_args(["-p", "ask"])
    names = Truffle::CLI.send(:print_tools, args, Dir.pwd).map(&:name)

    assert_equal %w[read write bash edit find grep], names
  end

  def test_print_tools_are_empty_under_no_tools
    args = Truffle::CLI.parse_args(["-p", "ask", "--no-tools"])

    assert_empty Truffle::CLI.send(:print_tools, args, Dir.pwd)
  end

  def test_print_tools_honor_a_whitelist_then_a_blacklist
    args = Truffle::CLI.parse_args(["-p", "ask", "--tools", "read,bash,edit",
                                    "--exclude-tools", "bash"])
    names = Truffle::CLI.send(:print_tools, args, Dir.pwd).map(&:name)

    assert_equal %w[read edit], names
  end
end
