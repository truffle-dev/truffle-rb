# frozen_string_literal: true

module Truffle
  class Session
    # Record session-level metadata. Today that is the user-facing display name
    # from the CLI's --name flag, porting pi's session_info entry. An empty
    # normalized value explicitly clears the name.
    def append_session_info(name)
      normalized = self.class.sanitize_session_name(name)
      fields = {}
      fields[:name] = normalized unless normalized.empty?
      append_typed("session_info", **fields)
    end

    def self.sanitize_session_name(name)
      name.to_s.gsub(/[\r\n]+/, " ").strip
    end

    # The latest session display name, or nil when absent or explicitly cleared.
    def session_name
      entry = @entries.reverse.find { |candidate| candidate[:type] == "session_info" }
      return nil unless entry

      name = self.class.sanitize_session_name(entry[:name])
      name.empty? ? nil : name
    end
  end
end
