# frozen_string_literal: true

require "test_helper"
require "tempfile"

class TestConfigValue < Minitest::Test
  include Truffle

  # The command cache and the process environment are process-global, so reset
  # both before each test. TCV_* names are the only environment keys these tests
  # touch; clearing them keeps a "missing" variable actually missing.
  def setup
    ConfigValue.clear_cache
    ENV.keys.grep(/\ATCV_/).each { |key| ENV.delete(key) }
  end

  def teardown
    ENV.keys.grep(/\ATCV_/).each { |key| ENV.delete(key) }
  end

  # --- literals and templates ------------------------------------------------

  def test_literal_resolves_to_itself
    assert_equal "hello", ConfigValue.resolve("hello")
  end

  def test_empty_string_resolves_to_empty_string
    assert_equal "", ConfigValue.resolve("")
  end

  def test_braced_variable_from_env_hash
    assert_equal "bar", ConfigValue.resolve("${TCV_FOO}", env: { "TCV_FOO" => "bar" })
  end

  def test_bare_variable_from_env_hash
    assert_equal "bar", ConfigValue.resolve("$TCV_FOO", env: { "TCV_FOO" => "bar" })
  end

  def test_variable_interpolated_between_literals
    assert_equal "a-x-b", ConfigValue.resolve("a-$TCV_FOO-b", env: { "TCV_FOO" => "x" })
  end

  def test_braced_variable_between_literals_with_no_separators
    assert_equal "axb", ConfigValue.resolve("a${TCV_FOO}b", env: { "TCV_FOO" => "x" })
  end

  def test_adjacent_variables
    assert_equal "12",
                 ConfigValue.resolve("${TCV_A}${TCV_B}", env: { "TCV_A" => "1", "TCV_B" => "2" })
  end

  def test_missing_variable_resolves_to_nil
    assert_nil ConfigValue.resolve("${TCV_MISS}", env: {})
  end

  def test_one_missing_variable_makes_the_whole_template_nil
    assert_nil ConfigValue.resolve("$TCV_A$TCV_B", env: { "TCV_A" => "1" })
  end

  def test_double_dollar_escapes_a_literal_dollar
    assert_equal "price$5", ConfigValue.resolve("price$$5")
  end

  def test_dollar_bang_escapes_a_literal_bang
    assert_equal "a!b", ConfigValue.resolve("a$!b")
  end

  def test_unterminated_brace_stays_literal
    assert_equal "${TCV_FOO", ConfigValue.resolve("${TCV_FOO", env: { "TCV_FOO" => "x" })
  end

  def test_invalid_brace_name_stays_literal
    # A name starting with a digit is not a valid variable, so the whole
    # ${...} is kept verbatim and references no variable.
    assert_equal "${1BAD}", ConfigValue.resolve("${1BAD}", env: {})
    assert_empty ConfigValue.env_var_names("${1BAD}")
  end

  def test_lone_dollar_before_non_name_stays_literal
    assert_equal "cost $ money", ConfigValue.resolve("cost $ money")
  end

  def test_trailing_dollar_stays_literal
    assert_equal "abc$", ConfigValue.resolve("abc$")
  end

  # --- environment fallback --------------------------------------------------

  def test_env_hash_empty_string_falls_through_to_process_env
    ENV["TCV_K"] = "from-process"

    assert_equal "from-process", ConfigValue.resolve("$TCV_K", env: { "TCV_K" => "" })
  end

  def test_empty_in_both_env_hash_and_process_is_absent
    ENV["TCV_K"] = ""

    assert_nil ConfigValue.resolve("$TCV_K", env: { "TCV_K" => "" })
  end

  def test_process_env_used_when_no_env_hash_given
    ENV["TCV_K"] = "proc-value"

    assert_equal "proc-value", ConfigValue.resolve("$TCV_K")
  end

  def test_env_hash_takes_precedence_over_process_env
    ENV["TCV_K"] = "proc-value"

    assert_equal "hash-value", ConfigValue.resolve("$TCV_K", env: { "TCV_K" => "hash-value" })
  end

  # --- shell commands --------------------------------------------------------

  def test_command_returns_trimmed_stdout
    assert_equal "hello", ConfigValue.resolve("!echo hello")
  end

  def test_command_runs_through_a_shell
    # The pipe only works if the command goes through a shell, not a bare exec.
    assert_equal "ab", ConfigValue.resolve("!printf 'a\\nb\\n' | tr -d '\\n'")
  end

  def test_command_leading_and_trailing_whitespace_is_trimmed
    assert_equal "hi", ConfigValue.resolve("!printf '  hi  \\n'")
  end

  def test_failing_command_resolves_to_nil
    assert_nil ConfigValue.resolve("!false")
  end

  def test_nonzero_exit_resolves_to_nil
    assert_nil ConfigValue.resolve_uncached("!exit 7")
  end

  def test_nonzero_exit_with_output_resolves_to_nil
    # The exit status is checked independently of whether the command printed
    # anything, so stdout on a failing command is still discarded.
    assert_nil ConfigValue.resolve("!echo out; exit 1")
  end

  def test_empty_command_output_resolves_to_nil
    assert_nil ConfigValue.resolve("!true")
  end

  # --- caching ---------------------------------------------------------------

  def test_command_result_is_cached
    file = Tempfile.new("tcv")
    file.write("one")
    file.close
    config = "!cat #{file.path}"

    assert_equal "one", ConfigValue.resolve(config)
    File.write(file.path, "two")

    assert_equal "one", ConfigValue.resolve(config), "second resolve should return the cached value"
  ensure
    file&.unlink
  end

  def test_resolve_uncached_bypasses_and_does_not_populate_the_cache
    file = Tempfile.new("tcv")
    file.write("one")
    file.close
    config = "!cat #{file.path}"

    assert_equal "one", ConfigValue.resolve(config)
    File.write(file.path, "two")

    assert_equal "two", ConfigValue.resolve_uncached(config)
    # The cached value from the first resolve is untouched.
    assert_equal "one", ConfigValue.resolve(config)
  ensure
    file&.unlink
  end

  def test_clear_cache_forces_a_rerun
    file = Tempfile.new("tcv")
    file.write("one")
    file.close
    config = "!cat #{file.path}"

    assert_equal "one", ConfigValue.resolve(config)
    File.write(file.path, "two")
    ConfigValue.clear_cache

    assert_equal "two", ConfigValue.resolve(config)
  ensure
    file&.unlink
  end

  def test_a_cached_failure_is_not_rerun
    # A command that records each run then fails. If the nil result is cached,
    # the second resolve must not run it again, so the marker file stays at one
    # line.
    marker = Tempfile.new("tcv-marker")
    marker.close
    config = "!echo run >> #{marker.path}; exit 1"

    assert_nil ConfigValue.resolve(config)
    assert_nil ConfigValue.resolve(config)
    assert_equal 1, File.read(marker.path).each_line.count
  ensure
    marker&.unlink
  end

  # --- predicates ------------------------------------------------------------

  def test_command_predicate
    assert ConfigValue.command?("!op read x")
    refute ConfigValue.command?("literal")
    refute ConfigValue.command?("$TCV_FOO")
    refute ConfigValue.command?("")
  end

  def test_env_var_name_for_a_single_variable
    assert_equal "TCV_FOO", ConfigValue.env_var_name("${TCV_FOO}")
    assert_equal "TCV_FOO", ConfigValue.env_var_name("$TCV_FOO")
  end

  def test_env_var_name_is_nil_for_mixed_or_multiple_parts
    assert_nil ConfigValue.env_var_name("a${TCV_FOO}")
    assert_nil ConfigValue.env_var_name("${TCV_A}${TCV_B}")
    assert_nil ConfigValue.env_var_name("literal")
    assert_nil ConfigValue.env_var_name("!cmd")
  end

  def test_env_var_names_are_unique_and_ordered
    assert_equal %w[TCV_A TCV_B], ConfigValue.env_var_names("$TCV_A-$TCV_B-$TCV_A")
    assert_empty ConfigValue.env_var_names("!cmd")
    assert_empty ConfigValue.env_var_names("literal")
  end

  def test_missing_env_var_names
    assert_equal %w[TCV_B],
                 ConfigValue.missing_env_var_names("$TCV_A-$TCV_B", env: { "TCV_A" => "1" })
    assert_empty ConfigValue.missing_env_var_names("$TCV_A", env: { "TCV_A" => "1" })
  end

  def test_configured_predicate
    assert ConfigValue.configured?("$TCV_A", env: { "TCV_A" => "1" })
    refute ConfigValue.configured?("$TCV_A-$TCV_B", env: { "TCV_A" => "1" })
    assert ConfigValue.configured?("!cmd")
    assert ConfigValue.configured?("literal")
  end

  # --- resolve_or_raise ------------------------------------------------------

  def test_resolve_or_raise_returns_the_value
    assert_equal "x",
                 ConfigValue.resolve_or_raise("${TCV_FOO}", "the key", env: { "TCV_FOO" => "x" })
  end

  def test_resolve_or_raise_names_a_single_missing_variable
    error = assert_raises(ConfigValue::ResolutionError) do
      ConfigValue.resolve_or_raise("${TCV_FOO}", "the key", env: {})
    end
    assert_equal "Failed to resolve the key from environment variable: TCV_FOO", error.message
  end

  def test_resolve_or_raise_names_several_missing_variables
    error = assert_raises(ConfigValue::ResolutionError) do
      ConfigValue.resolve_or_raise("$TCV_A$TCV_B", "the key", env: {})
    end
    assert_equal "Failed to resolve the key from environment variables: TCV_A, TCV_B", error.message
  end

  def test_resolve_or_raise_names_a_failed_command
    error = assert_raises(ConfigValue::ResolutionError) do
      ConfigValue.resolve_or_raise("!false", "the key")
    end
    assert_equal "Failed to resolve the key from shell command: false", error.message
  end

  # --- headers ---------------------------------------------------------------

  def test_resolve_headers_drops_unresolved_values
    headers = { "X" => "$TCV_FOO", "Y" => "lit", "Z" => "$TCV_MISS" }
    resolved = ConfigValue.resolve_headers(headers, env: { "TCV_FOO" => "bar" })

    assert_equal({ "X" => "bar", "Y" => "lit" }, resolved)
  end

  def test_resolve_headers_drops_empty_values
    assert_nil ConfigValue.resolve_headers({ "A" => "" }, env: {})
  end

  def test_resolve_headers_returns_nil_for_nil_headers
    assert_nil ConfigValue.resolve_headers(nil)
  end

  def test_resolve_headers_or_raise_resolves_all
    resolved = ConfigValue.resolve_headers_or_raise({ "X" => "$TCV_FOO" }, "provider",
                                                    env: { "TCV_FOO" => "bar" })

    assert_equal({ "X" => "bar" }, resolved)
  end

  def test_resolve_headers_or_raise_names_the_header
    error = assert_raises(ConfigValue::ResolutionError) do
      ConfigValue.resolve_headers_or_raise({ "Z" => "$TCV_MISS" }, "provider", env: {})
    end
    assert_equal 'Failed to resolve provider header "Z" from environment variable: TCV_MISS',
                 error.message
  end

  def test_resolve_headers_or_raise_returns_nil_for_nil_headers
    assert_nil ConfigValue.resolve_headers_or_raise(nil, "provider")
  end
end
