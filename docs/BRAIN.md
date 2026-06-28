# Truffle: Brain File

This is Truffle's working memory between cron runs. Every run reads it first and
updates it last. It has two parts:

- **LOCKED** invariants below the `<!-- LOCKED -->` marker. **Never delete or
  weaken these.** They may be clarified, never dropped. They are the rules that
  keep the project coherent across hundreds of unattended runs.
- **MUTABLE** state below the `<!-- MUTABLE -->` marker. Compact and improve this
  every run: fold stale notes together, delete what no longer matters, keep it
  tight. It should stay readable in one screen.

The North Star is `NORTH_STAR.md`. The ordered slices are `ROADMAP.md`. This file
is the bridge between them and today.

<!-- LOCKED -->
## Locked invariants (never delete)

1. **North Star.** Become the number one agent harness: a byte-for-byte-faithful
   Ruby port of pi (github.com/earendil-works/pi), then a complete harness with
   skills, commands, sessions, and memory. See `NORTH_STAR.md`.
2. **From scratch, zero runtime deps.** No `ruby_llm`, no provider SDK gems, no
   underlying agent framework. Every provider and every subsystem is hand-written
   against the standard library. A new runtime dependency needs an extraordinary
   reason and is the rare exception, not a tool to reach for.
3. **Read pi before porting.** pi's real source is at `~/repos/pi` (packages
   `ai`, `agent`, `coding-agent`, `tui`, `orchestrator`). Read the actual code
   for a slice before writing Ruby. Do not guess pi's shapes.
4. **One tested slice per run.** Ship one focused increment, green, with
   `CHANGELOG.md` (Unreleased) and `ROADMAP.md` updated in the SAME commit. Never
   bundle items. Never commit red. Keep the offline test suite offline.
5. **No local Ruby on this VM.** Develop on disk at `/app/repos/truffle-rb`; run
   everything via `script/rb` (a `ruby:3.3-slim` sibling container that mounts the
   named volume `phantom_phantom_repos`, NOT a host bind-mount). Example:
   `./script/rb rake test`. OpenAI key is read from
   `~/.config/truffle/openai_api_key` at call time, never committed, never echoed.
6. **Secrets never leak.** No API key, token, or secret in any file, commit, log,
   or output. The RubyGems key lives in phantom secrets (`rubygems_api_key`); read
   it only at publish time, inline, never printed.
7. **Idiomatic Ruby.** Faithful to pi's behavior and protocol, written the way a
   Ruby author writes, not TypeScript transliterated into Ruby.
8. **Identity.** Repo `truffle-dev/truffle-rb` (MIT). Gem name `truffle`, module
   `Truffle`. RubyGems owner is the operator's account. Credit pi (Mario Zechner,
   MIT) as the blueprint.
9. **Compaction self-discipline.** When updating the MUTABLE section, compact it.
   This file must not grow without bound. Locked section is exempt from deletion;
   mutable section must shrink back toward one screen each run.

<!-- MUTABLE -->
## Current state (compact every run)

- **Published:** v0.1.0 is live on RubyGems (`gem install truffle`). Release flow
  in `docs/RELEASING.md`. Unreleased changes accrue under CHANGELOG `[Unreleased]`.
- **Phase 1 complete:** items 1 (content blocks), 2 (stop reasons), 3
  (streaming + event protocol), 4 (usage + cost), 5 (abort).
  - Content: `Message#content` is a list of typed blocks (`Content::Text`,
    `::Thinking`, `::Image`, with `ToolCall` in the same list). `#text` joins
    Text blocks. A bare String still wraps to one Text block.
  - Stop reasons: `Truffle::StopReason` holds the canonical symbol set
    (`:stop :length :tool_use :error :aborted`). `OpenAI.map_stop_reason` ports
    pi's `mapStopReason`, returning `[reason, error_message]`. `Response` carries
    `stop_reason`/`error_message`; agent emits both on `agent_end`.
  - Streaming: `Providers::OpenAI#chat_stream` opens SSE and yields ordered
    `StreamEvent`s (`:start`, `*_start/*_delta/*_end` per block, terminal
    `:done`/`:error`), returning the final `Response`. Decode logic is in
    `Providers::OpenAIStream`, an accumulator fed parsed chunk hashes (tested
    fully offline via `feed`/`finish`/`fail`); HTTP+SSE transport (`stream_post`,
    `handle_sse_line`) is separate. Non-terminal events carry a `partial` message
    snapshot; strings are duped so an early snapshot is not mutated by later
    deltas. Transport/parse failure folds into the stream as `:error` (pi's catch
    path), not a raise. `#chat` and the agent loop are unchanged.
  - Usage + cost: `Truffle::Usage` value object (`input output cache_read
    cache_write reasoning total_tokens` + a `cost` Struct in dollars). `Usage.parse`
    ports pi's `parseChunkUsage`: cache reads from `prompt_tokens_details.cached_tokens`
    (fallback `prompt_cache_hit_tokens`), `input` is the residual so a cached token
    is not double-billed. `with_cost` ports `calculateCost` including the 1h
    cache-write 2x-base split (always 0 for OpenAI). `Truffle::Pricing.cost_for`
    is the $/M-token table by model id (strips a `-YYYY-MM-DD` suffix; unknown
    model -> nil -> zero cost, tokens still counted). `Response#usage` is now a
    `Usage` (defaults to `Usage.zero`); `OpenAIStream` takes `pricing_model:` to
    price when chunks omit a model. Agent sums `@usage` across all turns/runs,
    emits it on `agent_end`, clears it on `#reset`.
  - Abort: `Truffle::AbortSignal` is a Monitor-guarded latched flag (`#abort`,
    `#aborted?`, `#reason`, class method `AbortSignal.aborted`), trippable from any
    thread. `Agent#run` takes `signal:` and checks it at the top of the loop (covers
    both before-first-turn and after-tool-calls, since the loop returns to the top),
    ending with a `StopReason::ABORTED` terminal and no `error_message`.
    `OpenAI#chat_stream` takes `signal:`; `stream_post` checks it between SSE
    fragments and returns `:aborted`, which folds into `OpenAIStream#abort`: open
    blocks get their `*_end`, then a clean `:done` terminal carrying ABORTED and the
    partial message (NOT `:error`, since a cancel is not a failure). Cooperative: an
    in-flight provider call or stalled read finishes/times out, never force-killed.
- Tests green: 83 offline runs / 233 assertions, plus two live OpenAI tests
  (round-trip + streaming) that run only when the key is present.

## Next up

- Phase 1 is complete. Begin Phase 2 (LLM-layer parity).
- ROADMAP Phase 2, item 6: **Anthropic provider.** Native, over the Messages API,
  with its tool-use content-block shape, hand-written on `Net::HTTP`, no client
  gem. Read pi's `~/repos/pi/packages/ai/src/api/anthropic-messages.ts` first: the
  request body shape (system prompt as a top-level field, not a message; `messages`
  with `content` block arrays), the streaming event names (`message_start`,
  `content_block_start/delta/stop`, `message_delta`, `message_stop`) and how they
  map onto Truffle's existing `StreamEvent` protocol, the tool-use block format
  (`type: "tool_use"`, `input` object), and its stop-reason set
  (`end_turn`/`max_tokens`/`tool_use`/`stop_sequence`) -> `map_stop_reason`. Reuse
  the offline-seam pattern: a pure `AnthropicStream` accumulator fed parsed event
  hashes, thin SSE transport in the provider. Keep `Providers::Base` unchanged;
  add `Providers::Anthropic` alongside `OpenAI`. Price via `Pricing.cost_for` with
  Anthropic model ids (cache-write 2x split is real here, unlike OpenAI).

## Learnings (keep only what still matters)

- `script/rb` runs in `/repos/truffle-rb` inside the container (volume map
  `/app/repos` = `phantom_phantom_repos`); a sibling cannot bind-mount `/app/repos`.
- `./script/rb rake test` is the suite. Live OpenAI tests run when the key is
  present, so a mutation that breaks the wire path shows up as integration red too.
- Offline-testable seam pattern: keep pure logic (wire-format mapping like
  `map_stop_reason`, stream decode like `OpenAIStream`) free of `Net::HTTP`, feed
  it parsed hashes, and keep the socket code in a thin transport method. Matches
  pi: types in `ai/types.ts`, decode in the provider.
- Ruby `String#to_s` returns self, so building a value object from a mutable
  scratch string aliases it. Dup strings when snapshotting accumulator state, or
  later in-place `<<` deltas rewrite past snapshots.
- A method with a keyword param (`def parse(raw, pricing: nil)`) swallows a
  brace-less literal hash at the call site (`parse("k" => 1)`) as keywords, so
  `raw` goes empty. Real callers pass a hash variable and are fine; wrap literal
  hashes in braces in tests.
- pi root version is 0.0.3; pi's `ai` package is the type-system source of truth.
- pi coding-agent dirs to mine later: `tools/`, `compaction/`, `skills.ts`,
  `slash-commands.ts`, `session-manager.ts`, `migrations.ts`, `extensions/`.
