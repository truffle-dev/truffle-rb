# Roadmap

Pith grows slowly and steadily: one focused, tested increment at a time. The
north star is a complete, idiomatic Ruby port of the agent-core runtime in
[pi](https://github.com/earendil-works/pi), provider-agnostic in the spirit of
[ruby_llm](https://github.com/crmne/ruby_llm), usable end to end.

Each item below is a self-contained slice. When you pick one up, ship it with
tests green and a clear commit, then check it off here in the same commit. Do
not bundle items. Keep the loop in `lib/pith/agent.rb` readable.

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

## Next up (ordered)

1. **`ruby_llm` adapter provider.** `Pith::Providers::RubyLLM` wrapping a
   `ruby_llm` chat so every provider it supports works through Pith. Optional
   dependency, loaded only when used. Add an adapter test with a stubbed
   `ruby_llm` client.
2. **Streaming responses.** A `chat_stream` path on the provider seam plus a
   `:token` (or `:delta`) event so a UI can render text as it arrives. Keep the
   non-streaming `run` working unchanged.
3. **Anthropic provider.** A native `Pith::Providers::Anthropic` over the
   Messages API, including its tool-use content-block shape, so Pith is
   genuinely multi-provider without going through `ruby_llm`.
4. **Structured tool results.** Let a tool return a hash/array and serialize it
   as JSON for the model, while keeping plain strings working. Document the
   contract.
5. **Conversation persistence.** `Agent#dump` / `Agent.load` to round-trip
   message history (and tool definitions by name) so a session can be paused and
   resumed.
6. **Token + cost accounting.** Aggregate `usage` across turns and expose it on
   `agent_end`; add a small helper to estimate cost per provider/model.
7. **Retries and timeouts.** Configurable HTTP timeout and bounded retry with
   backoff in the OpenAI provider; surface failures as a typed error.
8. **Tool middleware.** A before/after hook around tool execution (logging,
   auth, rate limiting) without changing tool definitions.
9. **Multi-tool parallel dispatch.** When a model requests several tools in one
   turn, run independent ones concurrently while preserving result ordering in
   the message history.
10. **CLI.** A `pith` binary that loads a tools file and starts an interactive
    REPL against a chosen provider, rendering the event stream.

## Guiding constraints

- Provider-agnostic: nothing above the provider seam may assume OpenAI.
- Dependency-light: new runtime dependencies need a real justification.
- Readable: the core loop stays small enough to read in one sitting.
- Tested: every increment lands with tests; the offline suite stays offline.
