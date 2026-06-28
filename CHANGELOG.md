# Changelog

All notable changes to Pith are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the project aims to follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-06-28

First release. The agent-core runtime, ported from
[pi](https://github.com/earendil-works/pi) to plain Ruby.

### Added
- `Pith::Agent`: the agent loop (prompt -> tool calls -> tool results -> answer)
  with a `max_turns` guard and an ordered event stream.
- Tool DSL via `Pith.tool` / `Pith::Tool.define`: typed params, JSON Schema
  generation, string-key to keyword-arg symbolization, and error capture that
  feeds tool failures back to the model instead of crashing the loop.
- `Pith::Toolbox`: a named, enumerable collection of tools.
- Provider seam (`Pith::Providers::Base`) and a dependency-free OpenAI Chat
  Completions provider built on `Net::HTTP`.
- Event API (`Agent#on`) for `agent_start`, `turn_start`, `message`,
  `tool_call`, `tool_result`, `turn_end`, `agent_end`.
- `examples/calculator.rb`: a runnable multi-tool demo.
- Test suite: hermetic minitest tests plus one live OpenAI round-trip test,
  skipped unless `OPENAI_API_KEY` is set.
- `script/rb`: run any command in a `ruby:3.3-slim` container for hosts without
  a local Ruby.

[Unreleased]: https://github.com/truffle-dev/pith/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/truffle-dev/pith/releases/tag/v0.1.0
