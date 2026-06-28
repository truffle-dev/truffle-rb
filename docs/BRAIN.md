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

- **Published:** v0.1.0 is live on RubyGems (`gem install truffle`), installed
  and verified from a clean container. Release/upgrade flow documented in
  `docs/RELEASING.md`.
- **Repo identity migrated** from "Pith" to "Truffle" / `truffle-rb`: all code,
  docs, gemspec, `script/rb`, and examples renamed; ruby_llm framing removed;
  reframed as a from-scratch pi port. Tests green (14 runs / 46 assertions incl.
  live OpenAI round-trip).
- **Shipped this turn:** NORTH_STAR.md, this brain file, a rewritten ROADMAP
  (Phases 1–5 mapped to pi's package structure).

## Next up

- ROADMAP Phase 1, item 1: **content blocks**: port pi's typed content
  model (text / thinking / image / tool-call / tool-result) so a message is a
  list of typed blocks, not a single string. Read `~/repos/pi/packages/ai/src/types.ts`
  first.

## Learnings (keep only what still matters)

- `script/rb` runs in `/repos/truffle-rb` inside the container (volume map
  `/app/repos` = `phantom_phantom_repos`). A sibling container cannot bind-mount
  `/app/repos` directly.
- Test invocation that works:
  `./script/rb ruby -Ilib -Itest -e 'Dir["test/test_*.rb"].sort.each { |f| require File.expand_path(f) }'`.
- pi root version is 0.0.3; pi's `ai` package is the type-system source of truth.
- pi coding-agent core dirs to mine later: `tools/`, `compaction/`, `skills.ts`,
  `slash-commands.ts`, `session-manager.ts`, `migrations.ts`, `extensions/`.
