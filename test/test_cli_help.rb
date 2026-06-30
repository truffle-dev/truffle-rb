# frozen_string_literal: true

require "test_helper"

# Tests for the `--help` and `--version` output (Truffle::CLI::Help).
class TestCLIHelp < Minitest::Test
  def help(**kwargs)
    Truffle::CLI.help_text(**kwargs)
  end

  def test_version_text_names_the_binary_and_version
    assert_equal "truffle #{Truffle::VERSION}", Truffle::CLI.version_text
  end

  def test_help_opens_with_the_binary_name
    assert help.start_with?("truffle - AI coding assistant")
  end

  def test_help_includes_every_section_header
    text = help

    ["Usage:", "Options:", "Examples:", "Environment Variables:",
     "Built-in Tool Names:"].each do |header|
      assert_includes text, header
    end
  end

  def test_help_lists_the_real_built_in_tools
    text = help

    %w[read bash edit write grep find].each do |tool|
      assert_includes text, tool
    end
    # This harness ships no `ls` tool; pi's help line must not leak in.
    refute_includes text, "ls     List directory contents"
  end

  def test_help_lists_the_real_provider_env_vars
    text = help

    %w[ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY].each do |var|
      assert_includes text, var
    end
    assert_includes text, Truffle::Config::ENV_AGENT_DIR
    # pi documents ~40 provider keys; this harness has three, so a key for a
    # provider it cannot reach must not appear.
    refute_includes text, "GROQ_API_KEY"
  end

  def test_plain_help_has_no_ansi_escapes
    refute_includes help, "\e["
  end

  def test_color_help_bolds_section_headers
    text = help(color: true)

    assert_includes text, "\e[1mUsage:\e[0m"
    assert_includes text, "\e[1mOptions:\e[0m"
  end

  def test_help_ends_with_a_single_newline
    assert help.end_with?("\n")
    refute help.end_with?("\n\n")
  end

  # The load-bearing invariant: every flag the help advertises must be a flag the
  # parser actually recognizes. A documented flag that the parser treats as
  # unknown is a help/parser drift bug.
  def test_every_documented_flag_is_recognized_by_the_parser
    documented_flags(help).each do |flag|
      result = Truffle::CLI.parse_args([flag, "value"])

      assert_empty result.unknown_flags, "#{flag} landed in unknown_flags"
      errors = result.diagnostics.select { |d| d[:type] == :error }

      assert_empty errors, "#{flag} produced an error diagnostic: #{errors.inspect}"
    end
  end

  def test_documented_flags_extraction_finds_the_known_set
    flags = documented_flags(help)

    assert_includes flags, "--provider"
    assert_includes flags, "-p"
    assert_includes flags, "--no-context-files"
    assert_includes flags, "-nc"
  end

  private

  # Pull every leading flag token (--long or -short) out of the Options block.
  def documented_flags(text)
    options = text[/Options:\n(.*?)\n\n/m, 1]

    refute_nil options, "Options block not found in help text"
    options.lines.flat_map do |line|
      stripped = line.strip
      next [] unless stripped.start_with?("-")

      stripped.split(/\s{2,}/, 2).first.split(",").map(&:strip)
              .map { |token| token.sub(/\s*<.*>\z/, "").sub(/\s*\[.*\]\z/, "") }
              .select { |token| token.start_with?("-") }
    end
  end
end
