# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

# Behavior mirrors pi's coding-agent utils/paths.ts: isLocalPath,
# canonicalizePath, getCwdRelativePath, formatPathRelativeToCwdOrAbsolute.
class TestPaths < Minitest::Test
  include Truffle

  def test_remote_source_prefixes_are_not_local
    %w[npm:pkg git:host/repo github:user/repo http://x https://x ssh://x].each do |source|
      refute Paths.local_path?(source), "#{source.inspect} should be a remote source"
    end
  end

  def test_bare_relative_and_absolute_paths_are_local
    ["name", "./rel/path", "../up", "/abs/path", "sub/dir"].each do |path|
      assert Paths.local_path?(path), "#{path.inspect} should be local"
    end
  end

  def test_file_url_is_local
    # pi resolves a file: URL as a local path, so it is not in the remote set.
    assert Paths.local_path?("file:///abs/path")
  end

  def test_local_path_trims_before_classifying
    # pi trims the value first, so leading whitespace does not hide a remote prefix.
    refute Paths.local_path?("   git:host/repo")
    assert Paths.local_path?("   name")
  end

  def test_canonicalize_resolves_a_symlink
    Dir.mktmpdir do |dir|
      target = File.join(dir, "target")
      link = File.join(dir, "link")
      File.write(target, "x")
      File.symlink(target, link)

      assert_equal File.realpath(target), Paths.canonicalize(link)
    end
  end

  def test_canonicalize_falls_back_when_path_is_missing
    Dir.mktmpdir do |dir|
      missing = File.join(dir, "does-not-exist")

      assert_equal missing, Paths.canonicalize(missing)
    end
  end

  def test_cwd_relative_path_inside_cwd
    assert_equal "src/file.rb", Paths.cwd_relative_path("/home/u/proj/src/file.rb", "/home/u/proj")
  end

  def test_cwd_relative_path_for_cwd_itself_is_dot
    assert_equal ".", Paths.cwd_relative_path("/home/u/proj", "/home/u/proj")
  end

  def test_cwd_relative_path_outside_cwd_is_nil
    assert_nil Paths.cwd_relative_path("/home/u/other/file.rb", "/home/u/proj")
  end

  def test_cwd_relative_path_parent_is_nil
    assert_nil Paths.cwd_relative_path("/home/u", "/home/u/proj")
  end

  def test_cwd_relative_path_resolves_relative_input_against_cwd
    assert_equal "src/file.rb", Paths.cwd_relative_path("src/file.rb", "/home/u/proj")
  end

  def test_format_inside_cwd_is_relative
    inside = "/home/u/proj/src/file.rb"

    assert_equal "src/file.rb", Paths.format_relative_to_cwd_or_absolute(inside, "/home/u/proj")
  end

  def test_format_outside_cwd_is_absolute
    assert_equal "/home/u/other/file.rb",
                 Paths.format_relative_to_cwd_or_absolute("/home/u/other/file.rb", "/home/u/proj")
  end
end
