# frozen_string_literal: true

module Truffle
  class Session
    # Create a new session in cwd from an existing session file. The new header
    # gets its own id and timestamp, records the source file as parent_session,
    # and copies the source entries verbatim. This ports pi's SessionManager.forkFrom
    # while preserving Truffle's tool-name header so a forked CLI session can
    # rebind the same builtin tools on resume.
    def self.fork_from(source_path, cwd:, dir: Config.default_session_dir(cwd: cwd),
                       id: nil, now: Time.now)
      source_file = File.expand_path(source_path)
      source = load(source_file)
      id ||= UUID.v7
      SessionId.assert_valid!(id)
      timestamp = now.utc.iso8601(3)
      header = { type: "session", version: SESSION_VERSION, id: id, timestamp: timestamp,
                 cwd: cwd, parent_session: source_file }
      header[:tools] = source.tools if source.tools && !source.tools.empty?

      file = File.join(dir, "#{timestamp.gsub(/[:.]/, "-")}_#{id}.jsonl")
      new(store: FileStore.new(file), header: header, entries: source.entries, flushed: false).flush
    end
  end
end
