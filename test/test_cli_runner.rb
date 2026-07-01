# frozen_string_literal: true

require "test_helper"
require "fileutils"
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

# A REPL agent that supports both buffered and streaming runs. Streaming emits
# text deltas before the same agent_end payload the CLI uses for final status.
class StreamingPrintStubAgent
  attr_reader :buffered_prompts, :streamed_prompts

  def initialize(payload, chunks: [], events: nil)
    @payload = payload
    @events = events || chunks.map do |chunk|
      Truffle::StreamEvent.new(type: :text_delta, content_index: 0, delta: chunk)
    end
    @listeners = Hash.new { |h, k| h[k] = [] }
    @buffered_prompts = []
    @streamed_prompts = []
  end

  def on(event = nil, &block)
    @listeners[event || :_all] << block
    self
  end

  def run(prompt, images: [])
    @buffered_prompts << [prompt, images]
    emit(:agent_end, @payload)
    ""
  end

  def run_stream(prompt, images: [], &block)
    @streamed_prompts << [prompt, images]
    @events.each(&block)
    emit(:agent_end, @payload)
    ""
  end

  private

  def emit(event, payload)
    @listeners[event].each { |listener| listener.call(payload) }
    @listeners[:_all].each { |listener| listener.call(event, payload) }
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

# Captures each write while presenting itself as a terminal, so REPL tests can
# distinguish incremental deltas from one buffered final write.
class RecordingTTYOutput < StringIO
  attr_reader :writes, :flush_count

  def initialize
    super
    @writes = []
    @flush_count = 0
  end

  def tty? = true

  def write(string)
    @writes << string
    super
  end

  def flush
    @flush_count += 1
    super
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

  def run_repl_cli(argv, input:, agent: nil, out: StringIO.new)
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
      previous_agent_dir = ENV.fetch("TRUFFLE_AGENT_DIR", nil)
      ENV["TRUFFLE_AGENT_DIR"] = File.join(dir, ".truffle-agent")
      Dir.chdir(dir) { yield dir }
    ensure
      if previous_agent_dir.nil?
        ENV.delete("TRUFFLE_AGENT_DIR")
      else
        ENV["TRUFFLE_AGENT_DIR"] = previous_agent_dir
      end
    end
  end

  def create_cli_session(cwd)
    dir = Truffle::Config.default_session_dir(cwd: cwd, agent_dir: ENV.fetch("TRUFFLE_AGENT_DIR"))
    session = Truffle::Session.create(cwd: cwd, dir: dir)
    session.append_model_change(provider: "openai", model_id: "gpt-4o-mini")
    session.append_message(Truffle::Message.user("hello"))
    session.append_message(Truffle::Message.assistant(content: "hi"))
    session.flush
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
    agent = PrintStubAgent.new([])

    status, _out, err = run_repl_cli(["--thinking", "bogus"],
                                     input: StringIO.new("/exit\n"),
                                     agent: agent)

    assert_includes err, "Warning:"
    refute_includes err, "Error:"
    assert_equal 0, status
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

  def test_no_actionable_flag_runs_the_interactive_repl
    agent = PrintStubAgent.new([assistant_payload("hello")])

    status, out, err = run_repl_cli([], input: StringIO.new("hi\n/exit\n"), agent: agent)

    assert_equal 0, status
    assert_empty err
    assert_includes out, "Truffle interactive. Type /exit to quit."
    assert_includes out, "truffle> hello\n"
    assert_equal ["hi"], agent.prompts
  end

  def test_repl_streams_text_deltas_once_when_stdout_is_a_tty
    agent = StreamingPrintStubAgent.new(assistant_payload("hello"), chunks: %w[hel lo])
    output = RecordingTTYOutput.new

    status, out, err = run_repl_cli(
      [], input: StringIO.new("hi\n/exit\n"), agent: agent, out: output
    )

    assert_equal 0, status
    assert_empty err
    assert_equal [["hi", []]], agent.streamed_prompts
    assert_empty agent.buffered_prompts
    assert_equal %w[hel lo], output.writes.grep(/\A(?:hel|lo)\z/)
    assert_operator output.flush_count, :>=, 2
    assert_equal 1, out.scan("hello").length
  end

  def test_repl_separates_streamed_text_blocks
    events = [
      Truffle::StreamEvent.new(type: :text_start, content_index: 0),
      Truffle::StreamEvent.new(type: :text_delta, content_index: 0, delta: "first"),
      Truffle::StreamEvent.new(type: :text_end, content_index: 0, content: "first"),
      Truffle::StreamEvent.new(type: :text_start, content_index: 1),
      Truffle::StreamEvent.new(type: :text_end, content_index: 1, content: ""),
      Truffle::StreamEvent.new(type: :text_start, content_index: 2),
      Truffle::StreamEvent.new(type: :text_delta, content_index: 2, delta: "second"),
      Truffle::StreamEvent.new(type: :text_end, content_index: 2, content: "second")
    ]
    payload = {
      messages: [
        Truffle::Message.assistant(
          content: [
            Truffle::Content::Text.new(text: "first"),
            Truffle::Content::Text.new(text: "second")
          ]
        )
      ],
      stop_reason: Truffle::StopReason::STOP
    }
    agent = StreamingPrintStubAgent.new(payload, events: events)
    output = RecordingTTYOutput.new

    status, out, err = run_repl_cli(
      [], input: StringIO.new("hi\n/exit\n"), agent: agent, out: output
    )

    assert_equal 0, status
    assert_empty err
    assert_includes out, "first\nsecond\n"
    refute_includes out, "firstsecond"
  end

  def test_repl_keeps_buffered_output_when_stdout_is_not_a_tty
    agent = StreamingPrintStubAgent.new(assistant_payload("hello"), chunks: %w[hel lo])

    status, out, err = run_repl_cli([], input: StringIO.new("hi\n/exit\n"), agent: agent)

    assert_equal 0, status
    assert_empty err
    assert_equal [["hi", []]], agent.buffered_prompts
    assert_empty agent.streamed_prompts
    assert_includes out, "hello\n"
  end

  def test_repl_streaming_still_reports_error_turns
    payload = assistant_payload("", stop_reason: Truffle::StopReason::ERROR,
                                    error_message: "boom")
    agent = StreamingPrintStubAgent.new(payload, chunks: ["partial"])
    output = RecordingTTYOutput.new

    status, out, err = run_repl_cli(
      [], input: StringIO.new("hi\n/exit\n"), agent: agent, out: output
    )

    assert_equal 0, status
    assert_equal "boom\n", err
    assert_includes out, "partial\n"
    assert_equal 1, out.scan("partial").length
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

  def test_init_migrates_existing_unversioned_project_settings
    in_tmpdir do |dir|
      FileUtils.mkdir_p(".truffle")
      settings_json = JSON.pretty_generate({ "defaultProvider" => "openai" })
      File.write(".truffle/settings.json", "#{settings_json}\n")

      status, out, err = run_cli(["init"])

      assert_equal 0, status
      assert_empty err
      assert_includes out, "existing: .truffle/settings.json"
      assert_includes out, "migrated: .truffle/settings.json"

      settings = JSON.parse(File.read(File.join(dir, ".truffle", "settings.json")))

      assert_equal "openai", settings["defaultProvider"]
      assert_equal 1, settings["version"]
    end
  end

  def test_init_migrates_legacy_project_commands_before_scaffolding_prompts
    in_tmpdir do |dir|
      FileUtils.mkdir_p(".truffle/commands")
      File.write(".truffle/commands/deploy.md", "deploy safely")

      status, out, err = run_cli(["init"])

      assert_equal 0, status
      assert_empty err
      assert_includes out, "migrated: .truffle/prompts/"
      assert_includes out, "existing: .truffle/prompts/"
      refute_path_exists File.join(dir, ".truffle", "commands")
      assert_equal "deploy safely", File.read(File.join(dir, ".truffle", "prompts", "deploy.md"))
    end
  end

  def test_init_reports_unmigrated_malformed_project_settings
    in_tmpdir do
      FileUtils.mkdir_p(".truffle")
      File.write(".truffle/settings.json", "{")

      status, out, err = run_cli(["init"])

      assert_equal 0, status
      assert_includes out, "existing: .truffle/settings.json"
      refute_includes out, "migrated:"
      assert_includes err, "Warning: could not migrate .truffle/settings.json"
      assert_equal "{", File.read(".truffle/settings.json")
    end
  end

  def test_init_migrates_legacy_root_sessions
    in_tmpdir do |dir|
      agent_dir = ENV.fetch("TRUFFLE_AGENT_DIR")
      FileUtils.mkdir_p(agent_dir)
      header = {
        type: "session",
        version: Truffle::Session::SESSION_VERSION,
        id: "sess-1",
        timestamp: "2026-01-01T00:00:00.000Z",
        cwd: dir
      }
      File.write(File.join(agent_dir, "session.jsonl"), "#{JSON.generate(header)}\n")

      status, out, err = run_cli(["init"])

      assert_equal 0, status
      assert_empty err
      target = File.join(Truffle::Config.default_session_dir(cwd: dir, agent_dir: agent_dir),
                         "session.jsonl")

      assert_includes out, "migrated: #{target.delete_prefix("#{dir}/")}"
      assert_path_exists target
      refute_path_exists File.join(agent_dir, "session.jsonl")
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

  def test_repl_processes_initial_messages_before_the_input_loop
    agent = PrintStubAgent.new([
                                 assistant_payload("one reply"),
                                 assistant_payload("two reply"),
                                 assistant_payload("three reply")
                               ])

    status, out, err = run_repl_cli(
      %w[one two],
      input: StringIO.new("three\n/exit\n"),
      agent: agent
    )

    assert_equal 0, status
    assert_empty err
    assert_equal %w[one two three], agent.prompts
    assert_includes out, "one reply\n"
    assert_includes out, "two reply\n"
    assert_includes out, "three reply\n"
  end

  def test_repl_ignores_blank_input_and_exits_on_eof
    agent = PrintStubAgent.new([assistant_payload("unused")])

    status, out, err = run_repl_cli([], input: StringIO.new("\n  \n"), agent: agent)

    assert_equal 0, status
    assert_empty err
    assert_includes out, "Truffle interactive."
    assert_empty agent.prompts
  end

  def test_repl_reports_error_turns_and_continues
    agent = PrintStubAgent.new([
                                 assistant_payload("", stop_reason: Truffle::StopReason::ERROR,
                                                       error_message: "boom"),
                                 assistant_payload("recovered")
                               ])

    status, out, err = run_repl_cli([], input: StringIO.new("bad\ngood\n/exit\n"),
                                        agent: agent)

    assert_equal 0, status
    assert_equal "boom\n", err
    assert_includes out, "recovered\n"
    assert_equal %w[bad good], agent.prompts
  end

  def test_continue_print_loads_the_most_recent_session
    in_tmpdir do |dir|
      session = create_cli_session(dir)
      agent = PrintStubAgent.new([assistant_payload("continued")])
      loaded = nil

      Truffle::Agent.stub(:load, lambda { |path, **kwargs|
        loaded = [path, kwargs]
        agent
      }) do
        status, out, err = run_print_cli(["--continue", "-p", "again"])

        assert_equal 0, status
        assert_equal "continued\n", out
        assert_empty err
      end

      assert_equal session.file, loaded.first
      assert_nil loaded.last[:provider]
      assert_nil loaded.last[:model]
      assert_includes loaded.last[:system_prompt], "operating inside Truffle"
      assert_includes loaded.last[:system_prompt], "Current working directory: #{dir}"
      assert_equal ["again"], agent.prompts
    end
  end

  def test_continue_rebuilds_cli_system_prompt_with_append_sections
    in_tmpdir do |dir|
      session = create_cli_session(dir)
      agent = PrintStubAgent.new([assistant_payload("continued")])
      loaded = nil

      Truffle::Agent.stub(:load, lambda { |path, **kwargs|
        loaded = [path, kwargs]
        agent
      }) do
        status, out, err = run_print_cli([
                                           "--continue", "--append-system-prompt",
                                           "Stay terse.", "-p", "again"
                                         ])

        assert_equal 0, status
        assert_equal "continued\n", out
        assert_empty err
      end

      assert_equal session.file, loaded.first
      assert_includes loaded.last[:system_prompt], "\n\nStay terse.\nCurrent date:"
      assert_equal %w[read write bash edit find grep], loaded.last[:tools].map(&:name)
    end
  end

  def test_continue_repl_loads_the_most_recent_session
    in_tmpdir do |dir|
      session = create_cli_session(dir)
      agent = PrintStubAgent.new([assistant_payload("continued")])
      loaded_path = nil

      Truffle::Agent.stub(:load, lambda { |path, **_kwargs|
        loaded_path = path
        agent
      }) do
        status, out, err = run_repl_cli(["--continue"], input: StringIO.new("again\n/exit\n"))

        assert_equal 0, status
        assert_includes out, "continued\n"
        assert_empty err
      end

      assert_equal session.file, loaded_path
      assert_equal ["again"], agent.prompts
    end
  end

  def test_continue_without_a_session_reports_an_error
    in_tmpdir do
      status, out, err = run_print_cli(["--continue", "-p", "again"])

      assert_equal 1, status
      assert_empty out
      assert_includes err, "no session found"
    end
  end

  def test_resume_repl_prompts_for_a_session_and_loads_the_selection
    in_tmpdir do |dir|
      older = create_cli_session(dir)
      sleep 0.01
      newer = create_cli_session(dir)
      agent = PrintStubAgent.new([assistant_payload("resumed")])
      loaded_path = nil

      Truffle::Agent.stub(:load, lambda { |path, **_kwargs|
        loaded_path = path
        agent
      }) do
        status, out, err = run_repl_cli(["--resume"], input: StringIO.new("2\nagain\n/exit\n"))

        assert_equal 0, status
        assert_empty err
        assert_includes out, "Select a session to resume:"
        assert_includes out, "1. #{newer.id}"
        assert_includes out, "2. #{older.id}"
        assert_includes out, "resumed\n"
      end

      assert_equal older.file, loaded_path
      assert_equal ["again"], agent.prompts
    end
  end

  def test_resume_print_loads_the_selected_session_before_prompt_input
    in_tmpdir do |dir|
      session = create_cli_session(dir)
      agent = PrintStubAgent.new([assistant_payload("printed")])
      loaded_path = nil

      Truffle::Agent.stub(:load, lambda { |path, **_kwargs|
        loaded_path = path
        agent
      }) do
        status, out, err = run_print_cli(["--resume", "-p", "again"],
                                         input: StringIO.new("1\n"))

        assert_equal 0, status
        assert_empty err
        assert_includes out, "Select a session to resume:"
        assert_includes out, "printed\n"
      end

      assert_equal session.file, loaded_path
      assert_equal ["again"], agent.prompts
    end
  end

  def test_session_flag_can_load_a_session_from_another_project
    in_tmpdir do |dir|
      other_cwd = File.join(dir, "other-project")
      FileUtils.mkdir_p(other_cwd)
      session = create_cli_session(other_cwd)
      agent = PrintStubAgent.new([assistant_payload("global")])
      loaded_path = nil

      Truffle::Agent.stub(:load, lambda { |path, **_kwargs|
        loaded_path = path
        agent
      }) do
        status, out, err = run_print_cli(["--session", session.id, "-p", "again"])

        assert_equal 0, status
        assert_equal "global\n", out
        assert_empty err
      end

      assert_equal session.file, loaded_path
      assert_equal ["again"], agent.prompts
    end
  end

  def test_resume_without_sessions_exits_without_building_agent
    in_tmpdir do
      built = false
      out = StringIO.new
      err = StringIO.new

      status = Truffle::CLI.run(
        ["--resume"],
        out: out,
        err: err,
        input: StringIO.new(""),
        agent_builder: ->(_args) { built = true }
      )

      assert_equal 0, status
      assert_empty err.string
      assert_includes out.string, "No sessions found"
      refute built
    end
  end

  def test_resume_cancel_exits_without_loading_agent
    in_tmpdir do |dir|
      create_cli_session(dir)
      built = false
      out = StringIO.new
      err = StringIO.new

      status = Truffle::CLI.run(
        ["--resume"],
        out: out,
        err: err,
        input: StringIO.new("q\n"),
        agent_builder: ->(_args) { built = true }
      )

      assert_equal 0, status
      assert_empty err.string
      assert_includes out.string, "No session selected"
      refute built
    end
  end

  def test_resume_cannot_be_combined_with_continue
    status, out, err = run_cli(["--resume", "--continue"])

    assert_equal 1, status
    assert_empty out
    assert_includes err, "--resume cannot be combined with --continue"
  end

  def test_session_id_cannot_be_combined_with_continue
    status, out, err = run_cli(["--session-id", "project-1", "--continue"])

    assert_equal 1, status
    assert_empty out
    assert_includes err, "--session-id cannot be combined with --continue"
  end

  def test_invalid_session_id_reports_an_error
    status, out, err = run_cli(["--session-id", "../bad"])

    assert_equal 1, status
    assert_empty out
    assert_includes err, "Session id must be non-empty"
  end

  def test_fresh_repl_agent_is_session_backed_by_default
    in_tmpdir do |dir|
      args = Truffle::CLI.parse_args(["--provider", "openai", "--api-key", "test"])
      agent = Truffle::CLI.send(:build_cli_agent, args, cwd: dir)

      assert_instance_of Truffle::Session, agent.session
      assert_equal dir, agent.session.cwd
      assert_equal %w[read write bash edit find grep], agent.session.tools

      model_change = agent.session.entries.first

      assert_equal "model_change", model_change[:type]
      assert_equal "openai", model_change[:provider]
      assert_equal "gpt-4o-mini", model_change[:model_id]
    end
  end

  def test_fresh_repl_agent_uses_explicit_session_id
    in_tmpdir do |dir|
      args = Truffle::CLI.parse_args(["--provider", "openai", "--api-key", "test",
                                      "--session-id", "project.1-alpha"])
      agent = Truffle::CLI.send(:build_cli_agent, args, cwd: dir)

      assert_instance_of Truffle::Session, agent.session
      assert_equal "project.1-alpha", agent.session.id
      assert_match(/_project\.1-alpha\.jsonl\z/, File.basename(agent.session.file))
    end
  end

  def test_fresh_repl_agent_records_session_name
    in_tmpdir do |dir|
      args = Truffle::CLI.parse_args(["--provider", "openai", "--api-key", "test",
                                      "--name", "  Named\nRun  "])
      agent = Truffle::CLI.send(:build_cli_agent, args, cwd: dir)
      entry_types = agent.session.entries.map { |entry| entry[:type] }

      assert_equal "Named Run", agent.session.session_name
      assert_path_exists agent.session.file
      assert_equal %w[session_info model_change], entry_types
    end
  end

  def test_fresh_repl_with_existing_session_id_loads_that_session
    in_tmpdir do |dir|
      session = create_cli_session(dir)
      loaded = nil

      Truffle::Agent.stub(:load, lambda { |path, **kwargs|
        loaded = [path, kwargs]
        PrintStubAgent.new([assistant_payload("continued")])
      }) do
        args = Truffle::CLI.parse_args(["--session-id", session.id])
        Truffle::CLI.send(:build_cli_agent, args, cwd: dir)
      end

      assert_equal session.file, loaded.first
      assert_includes loaded.last[:system_prompt], "Current working directory: #{dir}"
    end
  end

  def test_name_is_written_to_selected_session_before_agent_load_failure
    in_tmpdir do |dir|
      session = create_cli_session(dir)

      Truffle::Agent.stub(:load, ->(_path, **_kwargs) { raise Truffle::Error, "bad model" }) do
        status, out, err = run_print_cli(["--session", session.file, "--name",
                                          "  CLI Named Session  ", "-p", "hi"])

        assert_equal 1, status
        assert_empty out
        assert_equal "bad model\n", err
      end

      assert_equal "CLI Named Session", Truffle::Session.load(session.file).session_name
    end
  end

  def test_whitespace_only_name_is_rejected_without_appending_metadata
    in_tmpdir do |dir|
      session = create_cli_session(dir)

      status, out, err = run_print_cli(["--session", session.file, "--name", "   ", "-p", "hi"])

      assert_equal 1, status
      assert_empty out
      assert_includes err, "--name requires a non-empty value"
      assert_nil Truffle::Session.load(session.file).session_name
    end
  end

  def test_fork_repl_copies_a_session_and_loads_the_fork
    in_tmpdir do |dir|
      source = create_cli_session(dir)
      agent = PrintStubAgent.new([assistant_payload("forked")])
      loaded = nil

      Truffle::Agent.stub(:load, lambda { |path, **kwargs|
        loaded = [path, kwargs]
        agent
      }) do
        status, out, err = run_repl_cli(["--fork", source.id, "--session-id", "fork-1"],
                                        input: StringIO.new("again\n/exit\n"))

        assert_equal 0, status
        assert_includes out, "forked\n"
        assert_empty err
      end

      forked = Truffle::Session.load(loaded.first)

      refute_equal source.file, loaded.first
      assert_equal "fork-1", forked.id
      assert_equal dir, forked.cwd
      assert_equal source.file, forked.parent_session
      assert_equal %w[hello hi], forked.messages.map(&:text)
      assert_nil forked.tools
      assert_equal ["again"], agent.prompts
    end
  end

  def test_fork_can_copy_a_session_from_another_project
    in_tmpdir do |dir|
      other_cwd = File.join(dir, "other-project")
      FileUtils.mkdir_p(other_cwd)
      source = create_cli_session(other_cwd)
      agent = PrintStubAgent.new([assistant_payload("forked")])
      loaded = nil

      Truffle::Agent.stub(:load, lambda { |path, **kwargs|
        loaded = [path, kwargs]
        agent
      }) do
        status, out, err = run_repl_cli(["--fork", source.id, "--session-id", "fork-global"],
                                        input: StringIO.new("again\n/exit\n"))

        assert_equal 0, status
        assert_includes out, "forked\n"
        assert_empty err
      end

      forked = Truffle::Session.load(loaded.first)

      refute_equal source.file, loaded.first
      assert_equal "fork-global", forked.id
      assert_equal dir, forked.cwd
      assert_equal source.file, forked.parent_session
      assert_equal %w[hello hi], forked.messages.map(&:text)
      assert_equal ["again"], agent.prompts
    end
  end

  def test_fork_rejects_an_existing_target_session_id
    in_tmpdir do |dir|
      session = create_cli_session(dir)

      status, out, err = run_repl_cli(["--fork", session.id, "--session-id", session.id],
                                      input: StringIO.new("/exit\n"))

      assert_equal 1, status
      assert_empty out
      assert_includes err, "Session already exists with id"
    end
  end

  def test_fork_cannot_be_combined_with_continue
    status, out, err = run_cli(["--fork", "abc", "--continue"])

    assert_equal 1, status
    assert_empty out
    assert_includes err, "--fork cannot be combined with --continue"
  end

  def test_no_session_keeps_a_fresh_repl_agent_ephemeral
    in_tmpdir do |dir|
      args = Truffle::CLI.parse_args(["--provider", "openai", "--api-key", "test",
                                      "--no-session"])
      agent = Truffle::CLI.send(:build_cli_agent, args, cwd: dir)

      assert_nil agent.session
    end
  end

  def test_fresh_print_agent_stays_sessionless
    in_tmpdir do |dir|
      args = Truffle::CLI.parse_args(["--provider", "openai", "--api-key", "test",
                                      "--print", "ask"])
      agent = Truffle::CLI.send(:build_cli_agent, args, cwd: dir)

      assert_nil agent.session
    end
  end

  def test_fresh_cli_agent_builds_system_prompt_for_enabled_tools
    in_tmpdir do |dir|
      args = Truffle::CLI.parse_args(["--provider", "openai", "--api-key", "test",
                                      "--no-session", "--tools", "read,bash"])
      agent = Truffle::CLI.send(:build_cli_agent, args, cwd: dir)

      assert_includes agent.system_prompt, "operating inside Truffle"
      assert_includes agent.system_prompt, "- read: Read the contents of a text file"
      assert_includes agent.system_prompt, "- bash: Execute a bash command"
      refute_includes agent.system_prompt, "- write:"
      assert_includes agent.system_prompt, "Current working directory: #{dir}"
    end
  end

  def test_fresh_cli_agent_honors_custom_and_appended_system_prompt
    in_tmpdir do |dir|
      args = Truffle::CLI.parse_args([
                                       "--provider", "openai", "--api-key", "test",
                                       "--no-session", "--system-prompt", "Base.",
                                       "--append-system-prompt", "First.",
                                       "--append-system-prompt", "Second."
                                     ])
      agent = Truffle::CLI.send(:build_cli_agent, args, cwd: dir)

      assert_includes agent.system_prompt, "Base.\n\nFirst.\n\nSecond."
      refute_includes agent.system_prompt, "Available tools:"
      assert_includes agent.system_prompt, "Current working directory: #{dir}"
    end
  end

  def test_fresh_cli_agent_loads_context_files_unless_disabled
    in_tmpdir do |dir|
      File.write("AGENTS.md", "Use short answers.")
      enabled = Truffle::CLI.parse_args(["--provider", "openai", "--api-key", "test",
                                         "--no-session"])
      disabled = Truffle::CLI.parse_args(["--provider", "openai", "--api-key", "test",
                                          "--no-session", "--no-context-files"])

      enabled_agent = Truffle::CLI.send(:build_cli_agent, enabled, cwd: dir)
      disabled_agent = Truffle::CLI.send(:build_cli_agent, disabled, cwd: dir)

      assert_includes enabled_agent.system_prompt, "<project_context>"
      assert_includes enabled_agent.system_prompt, "Use short answers."
      refute_includes disabled_agent.system_prompt, "Use short answers."
    end
  end

  def test_repl_with_an_unresolvable_model_errors_on_stderr_and_exits_one
    status, out, err = run_repl_cli([], input: StringIO.new("/exit\n"))

    assert_equal 1, status
    assert_empty out
    assert_includes err, "pass provider:"
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
