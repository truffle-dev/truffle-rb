# frozen_string_literal: true

require "yaml"

module Truffle
  # Parse the optional YAML frontmatter block at the head of a markdown file,
  # ported from pi's parseFrontmatter (utils/frontmatter.ts). A block is the text
  # between a leading "---" line and the next "---" line; everything after it is
  # the body. A file that does not start with "---", or that opens a block it
  # never closes, has no frontmatter and is all body. Newlines are normalized to
  # "\n" first, the block is parsed as YAML, and a parse that yields nil (an empty
  # block) becomes an empty hash, matching pi's `parse(yamlString) ?? {}`.
  #
  #   front, body = Truffle::Frontmatter.parse("---\nname: x\n---\nhi")
  #   front # => {"name" => "x"}
  #   body  # => "hi"
  module Frontmatter
    module_function

    # The parsed frontmatter hash (string keys, YAML scalar/collection values) and
    # the trimmed body. An absent block yields an empty hash and the whole file.
    def parse(content)
      yaml_string, body = extract(content)
      return [{}, body] unless yaml_string

      parsed = YAML.safe_load(yaml_string)
      [parsed || {}, body]
    end

    # Split content into its raw YAML string (or nil) and its body. The block runs
    # from just after the opening "---\n" to the next "\n---"; the body is what
    # follows that closing fence, stripped. Ports pi's extractFrontmatter, including
    # the slice offsets (4 past the opening fence, 4 past the closing one).
    def extract(content)
      normalized = content.gsub("\r\n", "\n").tr("\r", "\n")
      return [nil, normalized] unless normalized.start_with?("---")

      end_index = normalized.index("\n---", 3)
      return [nil, normalized] unless end_index

      [normalized[4...end_index], (normalized[(end_index + 4)..] || "").strip]
    end
  end
end
