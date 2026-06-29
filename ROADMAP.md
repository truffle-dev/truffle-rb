# Roadmap

Truffle is a byte-for-byte-faithful Ruby port of
[pi](https://github.com/earendil-works/pi), grown into a complete agent harness
with skills, commands, sessions, and memory. Everything is written from scratch
in plain Ruby with no runtime gem dependencies.

Truffle grows slowly and steadily: one focused, tested increment at a time. Each
item below is a self-contained slice. When you pick one up, ship it with tests
green and a clear commit, then check it off here in the same commit. Do not
bundle items. Keep the core loop in `lib/truffle/agent.rb` readable.

The ordering is a current best guess, not a contract. Read pi's real source
before each slice and let the port dictate the shape. If a better next slice
appears, add it; the goal is faithfulness to pi, then reach beyond it.

## Done (v0.1.0)

- [x] Tool DSL with typed params and JSON Schema generation
- [x] Toolbox (named, enumerable tool collection)
- [x] Message / ToolCall / Response value objects
- [x] Provider seam (`Providers::Base`)
- [x] OpenAI Chat Completions provider (dependency-free, `Net::HTTP`)
- [x] Agent loop with `max_turns` guard
- [x] Ordered event API (`agent_start` ... `agent_end`)
- [x] Error capture: a raising tool is reported back to the model
- [x] Hermetic test suite + one live OpenAI round-trip test
- [x] `script/rb` container runner; calculator example; docs; CI

## Phase 1: faithful agent-core port

Match pi's `packages/agent` and the type system in `packages/ai/src/types.ts`.

1. [x] **Content blocks.** Port pi's content model: text, thinking, image, and
   tool-call blocks on assistant messages; text/image/tool-result on user
   messages. A message is a list of typed blocks, not a single string.
2. [x] **Stop reasons.** Port `StopReason` (`stop` / `length` / `toolUse` /
   `error` / `aborted`) and surface it on the response and on `agent_end`.
3. [x] **Streaming + the event protocol.** Port pi's `AssistantMessageEvent`
   stream (`start`, `text_start/delta/end`, `thinking_*`, `toolcall_*`, `done`,
   `error`). A `chat_stream` path on the provider seam drives it; non-streaming
   `run` keeps working unchanged.
4. [x] **Usage + cost.** Aggregate `Usage` across turns; expose it on
   `agent_end`; add per-provider/model cost estimation.
5. [x] **Abort.** A cancellation signal that stops the loop mid-flight and yields
   an `aborted` stop reason cleanly.

## Phase 2: LLM layer parity (the `ai` package)

6. [x] **Anthropic provider.** Native, over the Messages API, with its tool-use
   content-block shape. Hand-written, no client gem. Both halves landed:
   non-streaming `#chat` and streaming `#chat_stream` over the same transforms,
   the latter decoding through an `AnthropicStream` accumulator and sharing the
   SSE transport with OpenAI via the `Providers::SSE` mixin.
7. [x] **Google / Gemini provider.** Native, over the Generative Language API,
   hand-written, no client gem. Both halves landed: non-streaming `#chat` over
   `generateContent` (`systemInstruction` extraction, `Content` role mapping,
   `functionCall`/`functionResponse` parts with single-user-turn coalescing,
   `parametersJsonSchema` tools, thought-signature handling, the `STOP`-to-
   `tool_use` override, `Usage.from_google`, and the Gemini catalog lineup), and
   streaming `#chat_stream` over `streamGenerateContent` (`?alt=sse`), decoding
   through a `GoogleStream` accumulator that keeps one open text-or-thinking
   block per chunk and emits a whole `functionCall` trio at once, sharing the SSE
   transport with OpenAI and Anthropic via the `Providers::SSE` mixin.
8. **Model catalog + provider registry.**
   - [x] **Model catalog.** A structured registry (`Truffle::Models`,
     `Truffle::Model`) of every model Truffle can address: id, provider, api,
     context window, max output, modalities, reasoning, deprecation, and a
     per-token cost hash, mirroring pi's generated `*.models.ts` tables and kept
     current to each provider's published docs. `Pricing` reads its rates; a
     freshness test guards against the lineup going stale.
   - [x] **Provider resolution.** Resolve a bare `model:` string to the right
     provider automatically the way pi's `ai` package does, so the caller need
     not also name the provider. `Models.resolve` ports pi's
     `findExactModelReferenceMatch` (bare id, canonical `provider/id`, dated
     snapshots, case-insensitive, ambiguity rejected); `Truffle.agent` infers the
     provider from `model:` and reduces a `provider/id` reference to the bare wire
     id.
9. [x] **Structured tool results.** A tool may return a hash/array, serialized
   as JSON for the model; plain strings keep working. `Tool#call` serializes any
   non-String return with `JSON.generate` (Infinity/NaN fall back to `to_s`),
   mirroring pi's `JSON.stringify` of a structured result.

## Phase 3: the coding-agent surface

Match `packages/coding-agent`: the tools and runtime that make an actual agent.

10. **Built-in tools.** bash, read, write, edit, glob, grep, written from
    scratch, matching pi's tool contracts and safety behavior.
    - [x] **read.** `Truffle::Tools.read` ports pi's `read.ts` text path: a
      `path` resolved against a bound cwd (or absolute), a 1-indexed `offset`, an
      optional line `limit`, head truncation at 2000 lines / 50KB via the shared
      `Truffle::Tools::Truncate` (a port of `truncate.ts`), and pi's continuation
      notices. Text-first: images and macOS path variants are out of scope.
    - [ ] bash, write, edit, glob, grep.
11. **Sessions + persistence.** `Agent#dump` / `Agent.load` to round-trip a
    session (history + tool definitions by name) so it can be paused and resumed.
12. **Compaction.** Summarize old turns to stay under context, preserving a
    locked, non-removable head (system prompt, pinned facts), mirroring how pi
    compacts.
13. **Retries + timeouts.** Configurable HTTP timeout and bounded backoff in each
    provider; typed errors.
14. **Tool middleware.** before/after hooks around tool execution (logging,
    auth, rate limiting) without changing tool definitions.
15. **Parallel tool dispatch.** Run independent tool calls in one turn
    concurrently while preserving result ordering in the history.

## Phase 4: self-extension (skills, commands, extensions)

16. **Skills.** A skill is a folder with a manifest and instructions, loadable at
    runtime, the way pi loads skills.
17. **Commands.** User-invocable commands that expand into prompts/actions.
18. **Extensions.** A plugin seam so third parties add tools, providers, and
    commands without forking.

## Phase 5: adoption + the CLI

19. **`truffle` binary.** Load a tools file, start an interactive REPL against a
    chosen provider, render the event stream.
20. **`truffle init` + config.** Create a project config dir, a memory file, and
    on-disk state. Document the layout.
21. **Migrations.** A versioned migration path for a host project's on-disk state
    (sessions, memory) so upgrades are safe.

## Guiding constraints

- Faithful to pi: read pi's real source before each slice; match its shapes.
- From scratch: no runtime gem dependencies; every provider hand-written.
- Readable: the core loop stays small enough to read in one sitting.
- Tested: every increment lands with tests; the offline suite stays offline.
