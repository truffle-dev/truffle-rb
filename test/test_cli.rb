# frozen_string_literal: true

require_relative "test_helper"

class TestCLI < Minitest::Test
  def parse(*argv)
    Truffle::CLI.parse_args(argv)
  end

  def test_empty_argv_yields_empty_collections
    args = parse

    assert_empty args.messages
    assert_empty args.file_args
    assert_empty args.unknown_flags
    assert_empty args.diagnostics
    assert_nil args.provider
    assert_nil args.append_system_prompt
  end

  def test_bare_tokens_become_messages
    args = parse("hello", "world")

    assert_equal %w[hello world], args.messages
  end

  def test_help_and_version_aliases
    assert parse("--help").help
    assert parse("-h").help
    assert parse("--version").version
    assert parse("-v").version
  end

  def test_value_flags_consume_the_next_argument
    args = parse("--provider", "openai", "--model", "gpt-4o", "--api-key", "sk-x")

    assert_equal "openai", args.provider
    assert_equal "gpt-4o", args.model
    assert_equal "sk-x", args.api_key
    assert_empty args.messages
  end

  def test_mode_only_accepts_known_values
    assert_equal "json", parse("--mode", "json").mode
    assert_equal "rpc", parse("--mode", "rpc").mode
    assert_nil parse("--mode", "bogus").mode
    assert_empty parse("--mode", "bogus").diagnostics
  end

  def test_thinking_validates_and_warns_on_unknown
    assert_equal "high", parse("--thinking", "high").thinking

    args = parse("--thinking", "ultra")

    assert_nil args.thinking
    assert_equal 1, args.diagnostics.length
    assert_equal :warning, args.diagnostics.first[:type]
    assert_includes args.diagnostics.first[:message], "ultra"
  end

  def test_name_requires_a_value
    args = parse("--name")

    assert_nil args.name
    assert_equal [{ type: :error, message: "--name requires a value" }], args.diagnostics
  end

  def test_name_with_value
    assert_equal "scratch", parse("--name", "scratch").name
    assert_equal "scratch", parse("-n", "scratch").name
  end

  def test_models_splits_and_trims_keeping_blanks_out_by_strip_only
    assert_equal ["anthropic/*", "*sonnet*"], parse("--models", "anthropic/*, *sonnet*").models
  end

  def test_tools_split_trims_and_drops_empties
    assert_equal %w[read bash], parse("--tools", "read, , bash,").tools
    assert_equal ["write"], parse("-xt", "write,").exclude_tools
  end

  def test_no_toggles
    args = parse("--no-session", "--no-tools", "--no-builtin-tools", "--no-extensions",
                 "--no-skills", "--no-prompt-templates", "--no-themes", "--no-context-files",
                 "--no-stream")

    assert args.no_session
    assert args.no_tools
    assert args.no_builtin_tools
    assert args.no_extensions
    assert args.no_skills
    assert args.no_prompt_templates
    assert args.no_themes
    assert args.no_context_files
    assert args.no_stream
  end

  def test_accumulator_flags_collect_in_order
    args = parse("-e", "ext-a", "--extension", "ext-b",
                 "--skill", "s1", "--prompt-template", "p1",
                 "--append-system-prompt", "more", "--theme", "dark")

    assert_equal %w[ext-a ext-b], args.extensions
    assert_equal ["s1"], args.skills
    assert_equal ["p1"], args.prompt_templates
    assert_equal ["more"], args.append_system_prompt
    assert_equal ["dark"], args.themes
  end

  def test_print_captures_a_following_message
    args = parse("--print", "do the thing")

    assert args.print
    assert_equal ["do the thing"], args.messages
  end

  def test_print_does_not_capture_a_flag_or_file_argument
    flag = parse("--print", "-c")

    assert flag.print
    assert flag.continue
    assert_empty flag.messages

    file = parse("--print", "@notes.md")

    assert file.print
    assert_equal ["notes.md"], file.file_args
    assert_empty file.messages
  end

  def test_print_captures_a_triple_dash_token
    args = parse("--print", "---raw")

    assert args.print
    assert_equal ["---raw"], args.messages
  end

  def test_list_models_with_and_without_pattern
    assert parse("--list-models").list_models
    assert_equal "sonnet", parse("--list-models", "sonnet").list_models
    bare = parse("--list-models", "-c")

    assert bare.list_models
    assert bare.continue
  end

  def test_init_is_a_command_not_a_prompt
    args = parse("init")

    assert args.init
    assert_empty args.messages
  end

  def test_init_keeps_normal_flag_parsing_after_the_command
    args = parse("init", "--help")

    assert args.init
    assert args.help
    assert_empty args.messages
  end

  def test_approve_sets_trust_override_both_ways
    assert parse("--approve").project_trust_override
    assert parse("-a").project_trust_override
    refute parse("--no-approve").project_trust_override
    refute parse("-na").project_trust_override
  end

  def test_file_args_strip_the_at_prefix
    args = parse("@a.rb", "@dir/b.rb")

    assert_equal ["a.rb", "dir/b.rb"], args.file_args
  end

  def test_unknown_long_flag_with_equals
    args = parse("--custom=value")

    assert_equal({ "custom" => "value" }, args.unknown_flags)
  end

  def test_unknown_long_flag_consumes_a_value
    args = parse("--custom", "value")

    assert_equal({ "custom" => "value" }, args.unknown_flags)
    assert_empty args.messages
  end

  def test_unknown_long_flag_without_a_value_records_true
    assert_equal({ "custom" => true }, parse("--custom").unknown_flags)
    assert_equal({ "custom" => true }, parse("--custom", "-c").unknown_flags)
  end

  def test_unknown_short_flag_is_an_error
    args = parse("-z")

    assert_equal [{ type: :error, message: "Unknown option: -z" }], args.diagnostics
  end

  def test_value_flag_at_end_with_no_value_falls_through_to_unknown_flag
    # pi's `arg === "--model" && i + 1 < length` guard is false here, so the
    # final unknown `--` branch claims it as a boolean flag.
    args = parse("--model")

    assert_nil args.model
    assert_equal({ "model" => true }, args.unknown_flags)
  end

  def test_session_family
    args = parse("--session", "abc", "--session-id", "proj-1",
                 "--fork", "old", "--session-dir", "/tmp/s")

    assert_equal "abc", args.session
    assert_equal "proj-1", args.session_id
    assert_equal "old", args.fork
    assert_equal "/tmp/s", args.session_dir
  end

  def test_mixed_flags_and_messages_round_trip
    args = parse("--provider", "anthropic", "summarize", "@file.txt", "-p", "now")

    assert_equal "anthropic", args.provider
    assert_equal %w[summarize now], args.messages
    assert_equal ["file.txt"], args.file_args
    assert args.print
  end

  def test_valid_thinking_level_predicate
    assert Truffle::CLI.valid_thinking_level?("xhigh")
    refute Truffle::CLI.valid_thinking_level?("turbo")
  end
end
