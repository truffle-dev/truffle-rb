# Changelog

All notable changes to Truffle are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the project aims to follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed
- Renamed the project from "Pith" to **Truffle** (gem `truffle`, module
  `Truffle`, repo `truffle-dev/truffle-rb`).
- Reframed as a from-scratch, byte-for-byte-faithful port of
  [pi](https://github.com/earendil-works/pi) with no runtime gem dependencies.
  Dropped the planned `ruby_llm` adapter; every provider is hand-written.

### Added
- Cooperative cancellation, ported from pi's `AbortSignal` threading through the
  agent loop and the streaming reader. `Truffle::AbortSignal` is a thread-safe
  token (`#abort`, `#aborted?`, `#reason`, and an `AbortSignal.aborted`
  constructor) that the owner of a run can trip from any thread. `Agent#run`
  takes `signal:` and checks it at turn boundaries, the point reached before each
  provider call and again after a batch of tool calls, so an abort stops the loop
  mid-flight and ends with a `StopReason::ABORTED` terminal instead of starting
  another turn. `Providers::OpenAI#chat_stream` takes `signal:` and checks it
  between socket reads; on cancel it stops reading and folds the turn into a clean
  `:done` terminal carrying `StopReason::ABORTED` and whatever content arrived,
  not an `:error`. Cancellation is cooperative: an in-progress provider call or a
  stalled socket read finishes or times out rather than being force-killed.
- Token usage and cost accounting, ported from pi's `Usage` type plus its
  `parseChunkUsage` and `calculateCost` helpers. `Truffle::Usage` is a value
  object carrying `input`, `output`, `cache_read`, `cache_write`, `reasoning`,
  and `total_tokens`, with a `cost` sub-struct in dollars. `Usage.parse` reads a
  provider's raw usage hash the way pi does: cache reads come from
  `prompt_tokens_details.cached_tokens` (falling back to `prompt_cache_hit_tokens`),
  and `input` is the residual so a cached prompt token is billed once as a read,
  not also as fresh input. `Truffle::Pricing.cost_for` looks up per-million-token
  rates by model id (stripping a date snapshot suffix; unknown models price at
  zero but still count tokens). `Response#usage` is now a `Usage`, and the agent
  sums usage across every turn of every run, exposing the running total on
  `agent_end` and clearing it on `#reset`.
- Streaming and the event protocol, ported from pi's `AssistantMessageEvent`
  stream. `Providers::OpenAI#chat_stream` opens an SSE request and yields ordered
  `Truffle::StreamEvent` objects as a turn arrives: one `:start`, then a
  `*_start`/`*_delta`/`*_end` trio per content block (text, thinking, or tool
  call), and a terminal `:done` or `:error` carrying the final message and
  StopReason. Each non-terminal event also carries a `partial` snapshot of the
  message so far. The decode logic lives in `Providers::OpenAIStream`, an
  accumulator fed parsed chunk hashes so it is tested fully offline; the HTTP and
  SSE transport stays in `#chat_stream`. A transport or parse failure folds into
  the stream as an `:error` event rather than raising, mirroring pi. The
  non-streaming `#chat` path and the agent loop are unchanged.
- Stop reasons, ported from pi's `StopReason` union
  (`stop`/`length`/`toolUse`/`error`/`aborted`). `Truffle::StopReason` holds the
  canonical set as symbols (`:stop`, `:length`, `:tool_use`, `:error`,
  `:aborted`); `Truffle::Providers::OpenAI.map_stop_reason` maps a Chat
  Completions `finish_reason` onto one (a faithful port of pi's `mapStopReason`),
  returning an error message for failure reasons. `Response#stop_reason` and
  `#error_message` carry the result, and the agent emits both on `agent_end`, so
  a caller can tell a clean finish from a length truncation or a content-filter
  error. The raw provider string stays available on `Response#finish_reason`.
- Typed content blocks (`Truffle::Content::Text`, `::Thinking`, `::Image`),
  ported from pi's content model. A `Message`'s content is now a list of these
  blocks instead of a single string; a bare String is wrapped as one Text block,
  and the model's tool calls live in the same list as `ToolCall` blocks rather
  than a side channel. `Message#text` joins the Text blocks; `#tool_calls` and
  `#tool_calls?` read off the content list. The public API is unchanged for the
  common case.
- Published to RubyGems: `gem install truffle`.
- `docs/RELEASING.md`: versioning, changelog, publish, and upgrade flow.
- `NORTH_STAR.md`: the project's fixed destination.
- `docs/BRAIN.md`: the self-updating continuity file (locked invariants plus a
  compacted mutable state) read and updated on every build run.
- Rewritten `ROADMAP.md` mapping Phases 1–5 to pi's package structure.

## [0.1.0] - 2026-06-28

First release. The agent-core runtime, ported from
[pi](https://github.com/earendil-works/pi) to plain Ruby.

### Added
- `Truffle::Agent`: the agent loop (prompt -> tool calls -> tool results -> answer)
  with a `max_turns` guard and an ordered event stream.
- Tool DSL via `Truffle.tool` / `Truffle::Tool.define`: typed params, JSON Schema
  generation, string-key to keyword-arg symbolization, and error capture that
  feeds tool failures back to the model instead of crashing the loop.
- `Truffle::Toolbox`: a named, enumerable collection of tools.
- Provider seam (`Truffle::Providers::Base`) and a dependency-free OpenAI Chat
  Completions provider built on `Net::HTTP`.
- Event API (`Agent#on`) for `agent_start`, `turn_start`, `message`,
  `tool_call`, `tool_result`, `turn_end`, `agent_end`.
- `examples/calculator.rb`: a runnable multi-tool demo.
- Test suite: hermetic minitest tests plus one live OpenAI round-trip test,
  skipped unless `OPENAI_API_KEY` is set.
- `script/rb`: run any command in a `ruby:3.3-slim` container for hosts without
  a local Ruby.

[Unreleased]: https://github.com/truffle-dev/truffle-rb/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/truffle-dev/truffle-rb/releases/tag/v0.1.0
