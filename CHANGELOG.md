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
- `Compaction.find_cut_point`, which chooses where to compact a session: it walks
  the conversation path backward summing the per-message estimate until the recent
  budget is met, then snaps the cut to a user or assistant boundary, never inside a
  tool result, and pulls back over settings entries so the first kept entry is a
  real boundary. When the cut lands inside a turn it reports the turn-start index
  and a split-turn flag. Ports pi's `findCutPoint`, `findValidCutPoints`, and
  `findTurnStartIndex`.
- `Truffle::Compaction`, the decision layer for context compaction, ported from
  the trigger half of pi's compaction. `estimate_tokens` gives a conservative
  per-message token estimate (four characters to a token, an image charged a flat
  budget, a tool call charged its name plus its JSON arguments; the system prompt
  is the locked head and estimates zero). `calculate_context_tokens` reads the
  context size of a provider usage block. `estimate_context_tokens(messages,
  usage:)` estimates a conversation, either purely from characters or, given the
  last known usage, as that measured total plus the estimate of the turns since.
  `should_compact?` reports whether context has crossed the window-minus-reserve
  threshold. `Compaction::Settings` and `DEFAULT_SETTINGS` carry pi's thresholds.
- `Agent#dump` and `Agent.load` to pause and resume an agent through a session
  file. `dump(dir:)` writes a new session: the conversation (the system prompt is
  left out, since it is regenerated from configuration on resume as in pi), a
  `model_change` recording the active model, and the toolbox's tool names in the
  header. `Agent.load(path, provider:, tools:, system_prompt:, model:)` reloads
  the session, rebinds the toolbox by name (every tool the dumped agent had must
  be supplied again, or load raises, since the model may still call it), restores
  the model recorded in the session (overridable with `model:`), and replays the
  history. The provider, the tool implementations, and the system prompt are
  re-supplied because they cannot be serialized. `Session.create` gains an
  optional `tools:` header field for this; it is omitted when empty, so a plain
  message session is written exactly as pi writes it.
- Session settings and compaction entries, and `Session#context`, ported from
  pi's `buildSessionContext`. Alongside message entries, a session can now record
  `append_model_change(provider:, model_id:)`, `append_thinking_level_change`, and
  `append_compaction(summary:, first_kept_entry_id:, tokens_before:)`.
  `Session#context` walks the leaf-to-root path and returns what a resumed agent
  should start from: the thinking level and model in force at the leaf (the
  latest such entry wins), and the messages to feed the model. When the path was
  compacted, those messages are the summary (wrapped in pi's `<summary>` framing)
  followed by the kept tail (the entries from `first_kept_entry_id` onward plus
  everything after the compaction), rather than the full history.
  `Session#messages` still returns the raw history for inspection. pi also lets an
  assistant message carry the active model; `Truffle::Message` has no provider or
  model field yet, so only `model_change` entries set the model for now. Branch
  summaries, labels, and v1/v2 migration remain follow-ups.
- An append-only session store (`Truffle::Session`), ported from pi's session
  manager. A session is a JSONL file: the first line is a header (`type`,
  `version`, `id`, `cwd`, optional `parent_session`) and every line after it is
  a message entry with its own `id`, the `parent_id` of the entry it follows,
  and a `timestamp`. Entries chain through `parent_id`, so the conversation is
  the leaf-to-root path through the file. `Session.create` writes the header and
  binds to the file, `append_message` appends one line per message and advances
  the leaf, `Session.load` parses the file back (skipping a truncated final
  line, as pi tolerates) and validates the header, and `messages` walks the leaf
  to the root and rebuilds the `Truffle::Message` list in order. Built on two
  new pieces: `Truffle::UUID` (a uuidv7 for the session id so ids sort in
  creation order, and an 8-hex short id for entries, both against the standard
  library) and `Message.from_h` / `Content.from_h`, the inverse of the existing
  `to_h` that rebuilds a turn block by block (tool calls included) when a session
  is read from disk. Branching, settings and compaction entries, labels, the
  deferred-first-flush optimization, and v1/v2 file migration are follow-ups.
- The `grep` built-in tool (`Truffle::Tools.grep`), ported from pi's `grep.ts`.
  It takes a `pattern` (a regular expression, or a literal string when `literal`
  is set), an optional `path` (a file or directory, default the current
  directory), an optional `glob` filter, and the `ignoreCase`, `context`, and
  `limit` switches. It returns `path:line: text` for each match and
  `path-line- text` for context lines, the same shape as pi (and `grep -C`). pi
  shells out to the `rg` binary (auto-downloaded) for the search and `.gitignore`
  handling; that pulls an external Rust tool, which breaks the zero-dependency
  and offline constraints, so this port scans the tree with Ruby's own `Regexp`
  and reuses `find` (and through it the `.gitignore` stack) for the file walk, so
  the same exclusions apply. Binary files (detected by a NUL byte) and unreadable
  files are skipped, as `rg` skips them; long lines are truncated to 500
  characters and the match count and 50KB byte ceiling produce pi's three
  bracketed notices. An empty result returns "No matches found".
- The `find` built-in tool (`Truffle::Tools.find`), ported from pi's `find.ts`.
  It takes a glob `pattern`, an optional `path` (default the current directory),
  and an optional `limit` (default 1000), and returns matching file paths
  relative to the search directory, one per line, posix-separated. pi's default
  implementation shells out to the `fd` binary (auto-downloaded) so it can honor
  `.gitignore`; that pulls an external Rust tool, which breaks the
  zero-dependency and offline constraints, so this port matches the tree
  natively with `Dir.glob` and mirrors pi's pluggable `FindOperations.glob`
  branch: `.git` and `node_modules` are excluded and hidden files are included.
  A bare pattern is prepended with `**/` so a basename like `*.rb` recurses, as
  fd's basename matching does. The result limit and the shared 50KB byte ceiling
  produce pi's bracketed notices, and an empty result returns "No files found
  matching pattern".
- `.gitignore` respect for `find` (`Truffle::Tools::Gitignore`). pi inherits this
  from fd's Rust `ignore` crate; since this port matches the tree itself, the
  rules are evaluated natively per gitignore(5): per-directory `.gitignore`
  files, last-match-wins with `!` negation, anchored (a slash in the pattern)
  versus floating patterns, directory-only trailing `/`, and the leading,
  trailing, and middle `**` forms. A directory excluded by a rule prunes
  everything beneath it, so a file cannot be re-included while its parent stays
  excluded. The hardcoded `.git`/`node_modules` floor and the `.gitignore` stack
  are both applied, mirroring fd's actual output. Not yet covered (faithful
  follow-ups): the global excludesfile, `.git/info/exclude`, `.ignore`/`.fdignore`
  files, and nested-repo boundaries.
- The `edit` built-in tool (`Truffle::Tools.edit`), ported from pi's `edit.ts`
  and the matching core in `edit-diff.ts`. It takes a `path` and an `edits`
  array of `{oldText, newText}` replacements. Each `oldText` is matched against
  the original file (exact match first, then a fuzzy fold that applies NFKC
  normalization, strips per-line trailing whitespace, and folds smart quotes,
  unicode dashes, and special spaces to ASCII), must be unique, and must not
  overlap another edit's match; at least one byte must change. The file's line
  endings (LF or CRLF) and a leading BOM are preserved, and the fuzzy path
  rewrites only the lines a replacement touches, copying every other line back
  byte for byte so unchanged blocks keep their exact content. pi's
  `prepareArguments` is ported too: an `edits` value sent as a JSON string is
  parsed, and a legacy top-level `oldText`/`newText` pair is folded onto the
  list. The error messages match pi verbatim (not found, non-unique, empty
  `oldText`, overlap, no change), so the agent loop reports the same guidance.
  pi's diff and unified-patch rendering feeds only the TUI and pulls in the
  `diff` package, so it is out of scope. Occurrence counting uses an escaped
  regexp split so a single-space `oldText` keeps literal semantics rather than
  Ruby's `split(" ")` whitespace-run behavior.
- The `bash` built-in tool (`Truffle::Tools.bash`), ported from pi's `bash.ts`.
  It runs a command under bash in a bound working directory with stdout and
  stderr combined in command order, and returns the raw output. An optional
  `timeout` (seconds, no default) kills the whole process group on expiry; a
  nonzero exit or a timeout raises with the captured output plus a status line,
  the way pi throws. Output is tail truncated (the end, where errors and results
  live) by the same two limits as `read` (2000 lines or 50KB, whichever hits
  first); when truncated, the full untruncated output is written to a temp file
  and the returned notice points at it. The notice's byte-limit branch reports
  pi's default 50KB constant rather than any applied limit, matching `bash.ts`.
  Truncation reuses a new `Truncate.tail` (a port of pi's `truncateTail`), which
  keeps the last lines or bytes and, for a single line that alone exceeds the
  byte budget, keeps the end of it on a character boundary. pi's streaming,
  memory-bounded `OutputAccumulator` is not ported: the engine buffers the full
  output and truncates at the end, which leaves the observable result identical.
- The `write` built-in tool (`Truffle::Tools.write`), ported from pi's
  `write.ts`. It resolves a path against a bound working directory, creates any
  missing parent directories, and writes UTF-8 content, creating the file or
  overwriting it. It returns a short confirmation naming the byte count and the
  path as passed. pi labels that count "bytes" while measuring `content.length`
  (UTF-16 code units); the port reports `content.bytesize`, the real byte count
  the label promises, which agrees with pi for ASCII and stays correct for
  multibyte content. Path resolution moves into a shared `Truffle::Tools::Path`
  module (a port of pi's `resolveToCwd`): unicode space variants fold to a plain
  space, a single leading `@` is stripped, and `~`/`~/` expand to the home
  directory before resolving against cwd. The `read` tool now resolves through
  the same module. file:// URLs are out of scope, matching read's original
  resolution.
- The `read` built-in tool (`Truffle::Tools.read`), the first concrete
  coding-agent tool, ported from pi's `read.ts`. It reads a UTF-8 text file
  relative to a bound working directory (or by absolute path), with a 1-indexed
  `offset` start line and an optional `limit` on lines returned. Output passes
  through head truncation at 2000 lines or 50KB (whichever is hit first), and a
  large or windowed read appends a continuation notice telling the model the next
  `offset` to use. A single line over the byte limit returns a byte-bounded bash
  fallback instead of flooding the context. The shared truncation utility it
  depends on (`Truffle::Tools::Truncate`, a port of pi's `truncate.ts`) lands
  alongside it for the bash and grep tools to come. Images and macOS path
  variants are out of scope for this text-first port.
- Structured tool results: a tool whose handler returns a Hash or Array (or any
  non-String value) now serializes that return as JSON for the model, the way pi
  stringifies a structured tool result. A String return still passes through
  verbatim, so a tool that formats its own text is unchanged. A value JSON cannot
  represent (Infinity, NaN) falls back to its plain string form rather than
  raising. This replaces the prior Ruby `inspect` rendering, which emitted
  `{:a=>1}` instead of valid JSON.
- Provider resolution from a model reference (`Models.resolve`,
  `Models.provider_for`, `Truffle.resolve_model`), a port of pi's
  `findExactModelReferenceMatch`. A reference is a bare id (`claude-opus-4-8`), a
  canonical `provider/id` (`anthropic/claude-opus-4-8`), or a dated snapshot of
  either; matching trims surrounding space and is case-insensitive. A bare id
  served by more than one provider is ambiguous and resolves to `nil` rather than
  guessing, while a named provider disambiguates it. `Truffle.agent` now accepts
  `model:` without `provider:`: the provider is inferred from the model and a
  `provider/id` reference is reduced to the bare wire id the provider expects. An
  explicit `provider:` is left untouched, so a custom or unlisted model id still
  works when the provider is named.
- A Google Gemini provider (`Providers::Google`, `provider: :google`) over the
  Generative Language API's `generateContent` endpoint, hand-written on
  `Net::HTTP` with no client gem. This is the non-streaming `#chat` half, a port
  of pi's `google-shared.ts`/`google-generative-ai.ts` wire shapes: the system
  prompt is lifted to a top-level `systemInstruction`, messages become Gemini
  `Content` with role `user`/`model`, tool calls are `functionCall` parts, tool
  results coalesce into one `user` turn of `functionResponse` parts, tools carry
  a `parametersJsonSchema`, and `tool_choice` maps to a `functionCallingConfig`
  mode. A thinking block is replayed as a `thought` part only when its signature
  is valid base64 (Gemini's TYPE_BYTES requirement), otherwise downgraded to
  plain text the way pi handles a cross-model replay. Gemini reports a plain
  `STOP` finish even when the turn is a tool call, so the stop reason is
  overridden to `tool_use` when the model asked for one. `Usage.from_google`
  parses `usageMetadata`, taking `input` as the residual after
  `cachedContentTokenCount` and folding `thoughtsTokenCount` into output while
  recording it as reasoning. The model catalog gains the Gemini lineup
  (3.5 Flash, 3.1 Pro Preview, 3.1 Flash-Lite, and the 2.5 Pro/Flash/Flash-Lite
  family) with current per-million pricing.
- A streaming Google provider (`Providers::Google#chat_stream`), the streaming
  counterpart to `#chat`. It opens an SSE request to `streamGenerateContent`
  (with `?alt=sse`) over the shared `Providers::SSE` transport and yields the
  same ordered `Truffle::StreamEvent` protocol the other providers do: one
  `:start`, a `*_start`/`*_delta`/`*_end` trio per block (text, thinking, or tool
  call), and a terminal `:done` or `:error` carrying the final message and
  StopReason. Unlike Anthropic's indexed block events, each Gemini chunk is a
  whole response whose candidate carries the parts produced since the last chunk,
  so the decode keeps one open text-or-thinking block and appends to it, closing
  it and opening a fresh one when the part kind flips (text to thought or back)
  or a `functionCall` arrives. A `functionCall` emits a complete
  `start`/`delta`/`end` trio at once, and the stop reason is overridden to
  `tool_use` when the turn produced a call (Gemini reports a plain `STOP` even
  then). A missing or duplicate call id is replaced with a deterministic
  name-and-counter id; the latest non-empty thought signature is retained; the
  cumulative `usageMetadata` is taken from the last chunk that carries it. The
  decode lives in a pure `Providers::GoogleStream` accumulator fed already-parsed
  chunk hashes, tested fully offline, and reuses every wire transform from
  `#chat`. A `SAFETY`/`RECITATION` finish folds into a terminal `:error`, and an
  `AbortSignal` folds into a clean `:done` with `StopReason::ABORTED`.
- A streaming Anthropic Messages provider (`Providers::Anthropic#chat_stream`),
  the streaming counterpart to `#chat`. It opens an SSE request and yields the
  same ordered `Truffle::StreamEvent` protocol the OpenAI provider does: one
  `:start`, a `*_start`/`*_delta`/`*_end` trio per content block (text, thinking,
  redacted thinking, or tool call), and a terminal `:done` or `:error` carrying
  the final message and StopReason. The decode lives in a pure
  `Providers::AnthropicStream` accumulator fed already-parsed event hashes, so it
  is tested fully offline: `message_start` seeds the response id and usage, each
  `content_block_start`/`delta`/`stop` drives one block keyed by its wire index,
  and `message_delta` carries the stop reason and final usage. Input tokens read
  at `message_start` survive a `message_delta` that omits them, while the delta's
  `output_tokens` wins. `tool_use` arguments assemble from `input_json_delta`
  fragments and parse once the block stops; a malformed buffer surfaces under a
  `_raw` key rather than crashing. A mid-stream `error` event, a `refusal`, or a
  stream that ends before `message_stop` all fold into a terminal `:error`, and
  an `AbortSignal` folds into a clean `:done` with `StopReason::ABORTED` carrying
  whatever content arrived. The SSE transport shared by both providers is
  factored into a `Providers::SSE` mixin (`#stream_post`, `#drive_stream`, line
  buffering, and tolerant data-line decode); each provider supplies only its auth
  headers and error label, so the two streaming paths cannot drift.
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
  compact `-20250929`). This is the non-streaming `#chat` half; the streaming
  `#chat_stream` over the same transforms is its own entry above.
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
- RuboCop linting with a tuned house-style config, plus a CI workflow that runs
  the offline suite across Ruby 3.1–3.4 (and `head`, allowed to fail), a RuboCop
  lint job, and a `gem build` packaging check, each a required gate.
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
