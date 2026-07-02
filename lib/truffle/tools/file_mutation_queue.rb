# frozen_string_literal: true

require "monitor"

module Truffle
  module Tools
    # Serialize file mutation operations that target the same file, while letting
    # operations on different files run in parallel. Port of pi's
    # file-mutation-queue.ts (packages/coding-agent/src/core/tools/).
    #
    # pi keeps one promise chain per resolved path in a global Map, guarded by a
    # single registration promise so the map's read-modify-write stays atomic. The
    # Ruby shape is a registry of one Mutex per key, guarded by a Monitor so the
    # look-up-or-create is atomic, plus a reference count so an idle key's entry is
    # dropped once no caller holds or waits on it. That count is the Ruby stand-in
    # for pi deleting the Map entry when the chain it appended is still the tail.
    module FileMutationQueue
      # A per-key mutex plus the number of callers currently holding or waiting on
      # it. The count keeps the entry alive across back-to-back mutations and lets
      # the last caller out delete it.
      Entry = Struct.new(:mutex, :refs)

      @registry = {}
      @lock = Monitor.new

      module_function

      # Run the block with exclusive access to file_path's mutation slot. The same
      # key gives the same mutex, so those blocks run one at a time; different keys
      # give different mutexes, so they run in parallel. Returns the block's value;
      # an exception raised inside propagates after the slot is released.
      def with(file_path, &)
        key = mutation_key(file_path)
        entry = acquire(key)
        begin
          entry.mutex.synchronize(&)
        ensure
          release(key)
        end
      end

      # The registry key: the real, symlink-resolved absolute path, so two names
      # for one file share a slot. When the file (or a parent directory) does not
      # exist yet, which is the create case, fall back to the merely-expanded path,
      # matching pi's ENOENT/ENOTDIR fallback.
      def mutation_key(file_path)
        resolved = File.expand_path(file_path)
        File.realpath(resolved)
      rescue Errno::ENOENT, Errno::ENOTDIR
        resolved
      end

      # Fetch the shared entry for key, creating it on first use, and count one
      # more caller in. Guarded so the fetch-or-create and the increment happen
      # atomically against other threads racing on the same key.
      def acquire(key)
        @lock.synchronize do
          entry = (@registry[key] ||= Entry.new(Mutex.new, 0))
          entry.refs += 1
          entry
        end
      end

      # Count a caller back out of key, and drop the entry once no caller holds or
      # waits on it, so the registry does not grow without bound.
      def release(key)
        @lock.synchronize do
          entry = @registry[key]
          return unless entry

          entry.refs -= 1
          @registry.delete(key) if entry.refs <= 0
        end
      end

      private_class_method :mutation_key, :acquire, :release
    end
  end
end
