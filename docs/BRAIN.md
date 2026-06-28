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
- **Phase 1 done so far:** item 1 (content blocks) and item 2 (stop reasons).
  - Content: `Message#content` is a list of typed blocks (`Content::Text`,
    `::Thinking`, `::Image`, with `ToolCall` in the same list). `#text` joins
    Text blocks; `#tool_calls?`/`#tool_calls` read off the list. A bare String
    still wraps to one Text block, so the common-case API is unchanged.
  - Stop reasons: `Truffle::StopReason` holds the canonical symbol set
    (`:stop :length :tool_use :error :aborted`, pi's `toolUse` -> `:tool_use`).
    `Providers::OpenAI.map_stop_reason(finish_reason)` is the faithful port of
    pi's `mapStopReason`; it returns `[reason, error_message]`. `Response` now
    carries `stop_reason` + `error_message` (raw string still on `finish_reason`).
    The agent emits both on `agent_end` from the loop-terminating response.
- Tests green: 35 runs / 101 assertions, incl. one live OpenAI round-trip (runs
  only when the key is present in the container).

## Next up

- ROADMAP Phase 1, item 3: **streaming + the event protocol.** Port pi's
  `AssistantMessageEvent` stream (`start`, `text_start/delta/end`, `thinking_*`,
  `toolcall_*`, `done`, `error`) as a `chat_stream` path on the provider seam;
  non-streaming `run` must keep working unchanged. Read
  `~/repos/pi/packages/ai/src/api/openai-completions.ts` (the SSE parse and the
  `stream.push({type: ...})` calls around lines 330-470) and the event-type union
  in `packages/ai/src/types.ts` first. The `done`/`error` events already carry a
  `reason` drawn from the StopReason set shipped this run.

## Learnings (keep only what still matters)

- `script/rb` runs in `/repos/truffle-rb` inside the container (volume map
  `/app/repos` = `phantom_phantom_repos`); a sibling cannot bind-mount `/app/repos`.
- `./script/rb rake test` is the suite. The live OpenAI test runs when the key is
  present, so a mutation that breaks tool calls shows up as integration red too.
- Provider wire-format mapping (like `map_stop_reason`) is a module method
  (`self.`) so it unit-tests offline with no network call. Keep canonical value
  sets in their own module (`StopReason`) and the mapping in the provider,
  matching pi: the type lives in `ai/types.ts`, `mapStopReason` in the provider.
- pi root version is 0.0.3; pi's `ai` package is the type-system source of truth.
- pi coding-agent dirs to mine later: `tools/`, `compaction/`, `skills.ts`,
  `slash-commands.ts`, `session-manager.ts`, `migrations.ts`, `extensions/`.
