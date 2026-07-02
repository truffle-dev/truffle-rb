# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class TestFileMutationQueue < Minitest::Test
  include Truffle::Tools

  # Each run gets a fresh temp directory so the paths under test are unique and
  # the process-global registry starts clean for them.
  def setup
    @dir = Dir.mktmpdir("truffle-fmq-")
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
  end

  # --- return value ----------------------------------------------------------

  def test_returns_the_block_value
    result = FileMutationQueue.with(File.join(@dir, "r.txt")) { 42 }

    assert_equal 42, result
  end

  # --- serialization ---------------------------------------------------------

  def test_same_file_mutations_run_one_at_a_time
    path = File.join(@dir, "a.txt")

    assert_equal 1, peak_concurrency(Array.new(5) { path })
  end

  def test_different_files_run_in_parallel
    paths = Array.new(3) { |i| File.join(@dir, "f#{i}.txt") }

    assert_equal 3, peak_concurrency(paths)
  end

  # --- key resolution --------------------------------------------------------

  def test_symlinked_names_share_one_slot
    # A file and a symlink to it resolve to the same real path, so mutations
    # through either name serialize against each other.
    real = File.join(@dir, "real.txt")
    File.write(real, "x")
    link = File.join(@dir, "link.txt")
    File.symlink(real, link)

    assert_equal 1, peak_concurrency([real, link])
  end

  def test_a_missing_path_still_gets_a_slot
    # The create case: the target does not exist yet, so realpath fails and the
    # key falls back to the resolved path. The mutation still runs.
    ran = false
    FileMutationQueue.with(File.join(@dir, "does", "not", "exist.txt")) { ran = true }

    assert ran
  end

  # --- cleanup and failure ---------------------------------------------------

  def test_idle_key_is_dropped_from_the_registry
    path = File.join(@dir, "clean.txt")
    FileMutationQueue.with(path) { :ok }

    registry = FileMutationQueue.instance_variable_get(:@registry)

    refute registry.key?(File.expand_path(path)),
           "expected the idle key to be removed from the registry"
  end

  def test_an_exception_inside_still_releases_the_slot
    path = File.join(@dir, "boom.txt")
    assert_raises(RuntimeError) do
      FileMutationQueue.with(path) { raise "boom" }
    end

    # The slot is free again: a following mutation acquires it without hanging.
    ran = false
    FileMutationQueue.with(path) { ran = true }

    assert ran
  end

  private

  # Run one queued block per key in +keys+ concurrently, each holding its slot
  # briefly, and report the highest number that were ever inside a block at once.
  # Keys that share a mutation slot cap this at 1; independent keys let it climb.
  def peak_concurrency(keys)
    lock = Mutex.new
    active = 0
    peak = 0
    threads = keys.map do |key|
      Thread.new do
        FileMutationQueue.with(key) do
          lock.synchronize do
            active += 1
            peak = [peak, active].max
          end
          sleep 0.05
          lock.synchronize { active -= 1 }
        end
      end
    end
    threads.each(&:join)
    peak
  end
end
