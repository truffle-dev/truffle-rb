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

- **Published:** v0.1.0 is live on RubyGems (`gem install truffle`), verified
  from a clean container. Release/upgrade flow in `docs/RELEASING.md`.
- **Phase 1 item 1 shipped (content blocks).** `lib/truffle/content.rb` holds
  `Content::Text`, `::Thinking`, `::Image`; `Message#content` is now a list of
  typed blocks, with `ToolCall` carried in the same list (not a side channel).
  `Message#text` joins Text blocks; `#tool_calls`/`#tool_calls?` read off the
  list; `to_h` emits block hashes. A bare String still wraps to one Text block,
  so the public API is unchanged for the common case. `Response#text` and the
  OpenAI provider read through `Message#text`. Tests green (25 runs / 77 assertions
  incl. live OpenAI round-trip).
- README now shows two real freeze-rendered terminal screenshots; the
  `truffle-build-advance` cron runs every 2 hours and the house voice (no AI
  jargon, no em-dashes, concise comments) is baked into `docs/CRON_PROMPT.md`.

## Next up

- ROADMAP Phase 1, item 2: **stop reasons.** Port pi's `StopReason`
  (`stop` / `length` / `toolUse` / `error` / `aborted`) and surface it on
  `Response` and on `agent_end`. Read `~/repos/pi/packages/ai/src/types.ts` and
  how `packages/agent` maps a provider finish reason onto it before porting.

## Learnings (keep only what still matters)

- `script/rb` runs in `/repos/truffle-rb` inside the container (volume map
  `/app/repos` = `phantom_phantom_repos`); a sibling cannot bind-mount `/app/repos`.
- `./script/rb rake test` is the suite. The live OpenAI test runs when the key
  is present in the container, so a mutation that breaks tool calls shows up as
  integration-test red too, not just unit red.
- Content normalization lives in `Message#coerce_block`: anything answering
  `#type` is kept as a block; everything else becomes a Text block via `to_s`.
  `ToolCall` answers `#type` (`:tool_call`), so it passes through untouched.
- pi root version is 0.0.3; pi's `ai` package is the type-system source of truth.
- pi coding-agent dirs to mine later: `tools/`, `compaction/`, `skills.ts`,
  `slash-commands.ts`, `session-manager.ts`, `migrations.ts`, `extensions/`.
