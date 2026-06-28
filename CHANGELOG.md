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
- A structured model catalog (`Truffle::Models`, `Truffle::Model`), the single
  source of truth for every model Truffle can address. Each `Model` carries its
  id, name, provider, api, context window, max output, input modalities,
  reasoning support, a deprecation flag, and a per-million-token cost hash
  (`:input`, `:output`, `:cache_read`, `:cache_write`), mirroring the fields pi
  keeps in its generated `*.models.ts` tables. The Anthropic and OpenAI lineups
  are transcribed from each provider's published model and pricing docs and kept
  current (Claude Fable 5, Opus 4.8 through 4.5, Sonnet 4.6/4.5, Haiku 4.5; the
  GPT-5.5/5.4/5 families, GPT-4.1, GPT-4o). `Truffle.models` lists them all and
  `Truffle.model(id)` resolves one, accepting a dated snapshot id
  (`gpt-4o-2024-08-06`, `claude-sonnet-4-5-20250929`) as its base model.
  `Truffle::Pricing` is now a thin facade reading rates off the catalog, so
  pricing can never drift from the model list. A freshness test fails loudly if
  the current flagships ever regress to a stale lineup.
- A native Anthropic Messages provider (`Providers::Anthropic`), ported from pi's
  `anthropic-messages.ts` wire shapes and hand-written on `Net::HTTP` with no
  client gem. `Truffle.agent(provider: :anthropic)` drives a full tool round
  trip. The request body follows the Messages API: the system prompt is lifted
  out of the message list into the top-level `system` field, `max_tokens` is
  always sent because the API requires it, message content is a block array, tool
  calls are `tool_use` blocks, and tool results come back as a `user` message of
  `tool_result` blocks with consecutive results coalesced into one message. Tool
  schemas go under `input_schema`. Assistant replay handles pi's edge cases: an
  empty text block is dropped, a redacted thinking block round-trips as
  `redacted_thinking`, and an unsigned thinking block is downgraded to plain text
  since Anthropic rejects unsigned thinking on replay. Stop reasons map onto
  `Truffle::StopReason` (`end_turn`/`stop_sequence`/`pause_turn` to stop,
  `max_tokens` to length, `tool_use` to tool use, `refusal`/`sensitive` to error
  with an explanation), and an unknown reason folds to an error carrying the raw
  string rather than crashing the loop. Usage is read with `Usage.from_anthropic`:
  `input_tokens` is taken directly (Anthropic reports it net of cache, unlike
  OpenAI's residual), and the 1h cache write is billed at twice base input.
  `Pricing` gains the Anthropic per-million-token table, and `base_model` now
  strips both date-snapshot forms (OpenAI's dashed `-2024-08-06` and Anthropic's
  compact `-20250929`). This is the non-streaming `#chat` half; a streaming
  `#chat_stream` over the same transforms is the next slice.
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
- RuboCop linting with a tuned house-style config, plus a best-in-class CI
  workflow: the offline suite across Ruby 3.1–3.4 (and `head`, allowed to fail),
  a RuboCop lint job, and a `gem build` packaging check, each a required gate.
- Published to RubyGems: `gem install truffle`.
- `docs/RELEASING.md`: versioning, changelog, publish, and upgrade flow.
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
