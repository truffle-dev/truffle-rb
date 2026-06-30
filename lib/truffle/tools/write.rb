# frozen_string_literal: true

require "fileutils"
require_relative "path"

module Truffle
  module Tools
    WRITE_DESCRIPTION =
      "Write content to a file. Creates the file if it doesn't exist, " \
      "overwrites if it does. Automatically creates parent directories."

    # Build pi's `write` tool, bound to a working directory. The path resolves
    # against cwd; parent directories are created as needed; the content is
    # written UTF-8, creating the file or overwriting it. Returns a short
    # confirmation naming the byte count and the path the model passed.
    def self.write(cwd: Dir.pwd)
      Tool.define("write", WRITE_DESCRIPTION, execution_mode: :sequential) do
        param :path, :string, "Path to the file to write (relative or absolute)", required: true
        param :content, :string, "Content to write to the file", required: true
        run do |path:, content:|
          Truffle::Tools.write_file(path: path, content: content, cwd: cwd)
        end
      end
    end

    # The write core, a port of write.ts's execute path: mkdir -p the parent,
    # write the bytes, report. pi labels the count "bytes" but measures
    # content.length (UTF-16 code units); we report content.bytesize, the real
    # byte count the label promises. The two agree for ASCII and bytesize is
    # correct for multibyte content. The confirmation echoes the path the model
    # passed, not the resolved absolute, exactly as pi does.
    def self.write_file(path:, content:, cwd:)
      absolute = Path.resolve(path, cwd)
      FileUtils.mkdir_p(File.dirname(absolute))
      File.write(absolute, content)
      "Successfully wrote #{content.bytesize} bytes to #{path}"
    end
  end
end
