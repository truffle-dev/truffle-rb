# frozen_string_literal: true

module Truffle
  # Validation for caller-supplied session ids. The default ids are UUIDv7, but
  # the CLI also lets a user choose a stable project id; keeping the allowed
  # characters narrow prevents surprising file names.
  module SessionId
    PATTERN = /\A[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?\z/
    ERROR =
      "Session id must be non-empty, contain only alphanumeric characters, " \
      "'-', '_', and '.', and start and end with an alphanumeric character"

    module_function

    def valid?(id)
      id.is_a?(String) && id.match?(PATTERN)
    end

    def assert_valid!(id)
      raise ArgumentError, ERROR unless valid?(id)
    end
  end
end
