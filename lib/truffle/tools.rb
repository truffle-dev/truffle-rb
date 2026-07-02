# frozen_string_literal: true

# Built-in tools: the concrete tools that make Truffle an agent that can act on a
# project, ported from pi's coding-agent. Each lives in its own file under
# tools/ and is built by a factory bound to a working directory. `read` is the
# first; write, bash, edit, find, grep, and ls follow.
require_relative "tools/truncate"
require_relative "tools/path"
require_relative "tools/read"
require_relative "tools/write"
require_relative "tools/bash"
require_relative "tools/edit"
require_relative "tools/find"
require_relative "tools/grep"
require_relative "tools/ls"
