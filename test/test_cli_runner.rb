# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"
require "tmpdir"

# A stand-in for the agent a `--print` run drives, with no provider and no
# network. It records the prompts it is sent and replays a scripted `:agent_end`
# payload after each run, so the dispatch's prompt assembly and final-response
# capture can be exercised offline. Later runs replay later payloads (clamped to
# the last), which is how the "last assistant turn wins" rule gets proven.
class PrintStubAgent
  attr_reader :prompts, :image_batches

  def initialize(payloads)
    @payloads = payloads
    @listeners = Hash.new { |h, k| h[k] = [] }
    @all_listeners = []
    @prompts = []
    @image_batches = []
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

  def run(prompt, images: [])
    @prompts << prompt
    @image_batches << images
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

  def in_tmpdir
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) { yield dir }
    end
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

  def test_init_creates_project_state_and_memory_file
    in_tmpdir do |dir|
      status, out, err = run_cli(["init"])

      assert_equal 0, status
      assert_empty err
      assert_includes out, "Initialized Truffle project."
      assert_includes out, "created: .truffle/"
      assert_includes out, "created: .truffle/settings.json"
      assert_includes out, "created: AGENTS.md"

      assert_path_exists File.join(dir, ".truffle")
      assert_path_exists File.join(dir, ".truffle", "prompts")
      assert_path_exists File.join(dir, ".truffle", "extensions")
      assert_path_exists File.join(dir, ".truffle", "skills")
      assert_path_exists File.join(dir, ".truffle", "sessions")
      settings = JSON.parse(File.read(File.join(dir, ".truffle", "settings.json")))

      assert_equal({ "version" => 1 }, settings)
      assert_includes File.read(File.join(dir, "AGENTS.md")), "Project Instructions"
    end
  end

  def test_init_is_idempotent_and_does_not_clobber_agents_file
    in_tmpdir do |dir|
      File.write("AGENTS.md", "keep me")

      status, out, err = run_cli(["init"])

      assert_equal 0, status
      assert_empty err
      assert_equal "keep me", File.read(File.join(dir, "AGENTS.md"))
      assert_includes out, "existing: AGENTS.md"
      assert_includes out, "created: .truffle/"

      status, out, err = run_cli(["init"])

      assert_equal 0, status
      assert_empty err
      assert_includes out, "existing: .truffle/"
      assert_includes out, "existing: .truffle/settings.json"
      refute_includes out, "created:"
    end
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

  def test_print_splices_text_file_arguments_into_the_initial_prompt
    in_tmpdir do |dir|
      path = File.join(dir, "note.txt")
      File.write(path, "alpha\nbeta")
      agent = PrintStubAgent.new([assistant_payload("ok")])

      status, = run_print_cli(["-p", "@note.txt"], agent: agent)

      assert_equal 0, status
      assert_equal ["<file name=\"#{path}\">\nalpha\nbeta\n</file>\n"], agent.prompts
    end
  end

  def test_print_orders_stdin_files_and_the_first_message_like_pi
    in_tmpdir do |dir|
      path = File.join(dir, "context.txt")
      File.write(path, "from file")
      agent = PrintStubAgent.new([assistant_payload("ok")])

      status, = run_print_cli(
        ["-p", "@context.txt", "ask", "followup"],
        input: StringIO.new("from stdin\n"),
        agent: agent
      )
      expected = "from stdin\n<file name=\"#{path}\">\nfrom file\n</file>\nask"

      assert_equal 0, status
      assert_equal [expected, "followup"], agent.prompts
    end
  end

  def test_print_skips_empty_file_arguments
    in_tmpdir do
      File.write("empty.txt", "")
      agent = PrintStubAgent.new([assistant_payload("ok")])

      status, = run_print_cli(["-p", "@empty.txt", "ask"], agent: agent)

      assert_equal 0, status
      assert_equal ["ask"], agent.prompts
    end
  end

  def test_print_reports_a_missing_file_argument
    in_tmpdir do |dir|
      agent = PrintStubAgent.new([assistant_payload("unused")])

      status, out, err = run_print_cli(["-p", "@missing.txt"], agent: agent)

      assert_equal 1, status
      assert_empty out
      assert_equal "Error: File not found: #{File.join(dir, "missing.txt")}\n", err
      assert_empty agent.prompts
    end
  end

  def test_print_attaches_supported_image_file_arguments_to_the_initial_prompt
    in_tmpdir do |dir|
      path = File.join(dir, "image.jpg")
      data = [0xff, 0xd8, 0xff, 0xe0].pack("C*")
      File.binwrite(path, data)
      agent = PrintStubAgent.new([assistant_payload("ok")])

      status, out, err = run_print_cli(["-p", "@image.jpg", "describe"], agent: agent)

      assert_equal 0, status
      assert_equal "ok\n", out
      assert_empty err
      assert_equal ["<file name=\"#{path}\"></file>\ndescribe"], agent.prompts

      image = agent.image_batches.first.first

      assert_instance_of Truffle::Content::Image, image
      assert_equal "image/jpeg", image.mime_type
      assert_equal [data].pack("m0"), image.data
    end
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
