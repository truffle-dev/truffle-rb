# Roadmap

The North Star is in [NORTH_STAR.md](NORTH_STAR.md): a byte-for-byte-faithful
Ruby port of [pi](https://github.com/earendil-works/pi), grown into a complete
agent harness with skills, commands, sessions, and memory. Everything is written
from scratch in plain Ruby with no runtime gem dependencies.

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
3. **Streaming + the event protocol.** Port pi's `AssistantMessageEvent` stream
   (`start`, `text_start/delta/end`, `thinking_*`, `toolcall_*`, `done`,
   `error`). A `chat_stream` path on the provider seam drives it; non-streaming
   `run` keeps working unchanged.
4. **Usage + cost.** Aggregate `Usage` across turns; expose it on `agent_end`;
   add per-provider/model cost estimation.
5. **Abort.** A cancellation signal that stops the loop mid-flight and yields a
   `aborted` stop reason cleanly.

## Phase 2: LLM layer parity (the `ai` package)

6. **Anthropic provider.** Native, over the Messages API, with its tool-use
   content-block shape. Hand-written, no client gem.
7. **Google / Gemini provider.** Same seam, native wire format.
8. **Provider registry + model catalog.** Resolve `model:` strings to the right
   provider the way pi's `ai` package does.
9. **Structured tool results.** A tool may return a hash/array, serialized as
   JSON for the model; plain strings keep working.

## Phase 3: the coding-agent surface

Match `packages/coding-agent`: the tools and runtime that make an actual agent.

10. **Built-in tools.** bash, read, write, edit, glob, grep, written from
    scratch, matching pi's tool contracts and safety behavior.
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
