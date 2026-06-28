# North Star

**Become the number one agent harness in Ruby — and a serious agent harness by
any language's standard — by faithfully porting [pi](https://github.com/earendil-works/pi)
to Ruby from scratch, then growing past it.**

This file is the fixed point. The roadmap, the brain file, and every cron run
serve this. It does not narrow into a single next step; it describes the
destination so any step can be checked against it.

## The two-part mission

1. **Byte-for-byte-faithful port of pi.** pi (by Mario Zechner / earendil-works,
   MIT) is a self-extensible coding-agent harness: a unified multi-provider LLM
   layer, an agent-core runtime with tool calling and state, an event-streaming
   protocol, sessions, skills, slash commands, compaction, extensions, and a
   coding-agent CLI. The first half of the mission is to reproduce pi's behavior
   in idiomatic Ruby — same shapes, same protocol, same semantics — so that a
   reader who knows pi recognizes Truffle immediately, and a Truffle user gets
   pi's capabilities in their own language.

2. **Then go beyond.** Once the core is faithful, extend into a complete harness:
   every capability a modern agent needs — skills, commands, sessions, memory,
   compaction, migrations, extensions, a CLI, and whatever the ecosystem is
   missing. The bar is not "a small Ruby gem." The bar is "the agent harness a
   serious Ruby team reaches for, and the one people port their ideas *to*."

## Built from scratch — no dependencies

Truffle is written from the ground up in plain Ruby and the standard library.
The LLM clients, the tool layer, the event protocol, the session and memory
machinery — all hand-written. **No `ruby_llm`, no provider SDK gems, no agent
framework underneath.** Every provider is implemented directly against its wire
API. This is a deliberate constraint: the whole thing should be auditable, and
its behavior should be ours, not inherited. A new runtime dependency needs an
extraordinary reason.

## What faithful means

- Read pi's actual source (`~/repos/pi`, packages `ai`, `agent`, `coding-agent`,
  `tui`, `orchestrator`) before porting a slice. Do not guess pi's shape — read
  it.
- Match pi's type system: content blocks (text / thinking / image / tool-call /
  tool-result), `Message` variants, `Usage`, `StopReason`
  (`stop`/`length`/`toolUse`/`error`/`aborted`), the `Tool` schema, and the
  `AssistantMessageEvent` streaming protocol (`start`, `text_*`, `thinking_*`,
  `toolcall_*`, `done`, `error`).
- Match pi's coding-agent surface: built-in tools (bash, read, write, edit,
  glob, grep), sessions, compaction, skills, slash commands, settings, model
  registry/resolver, extensions, migrations.
- Idiomatic, not transliterated. Faithful to behavior and protocol, written the
  way a Ruby author would write it. A reader should not see TypeScript-in-Ruby.

## Adoption is part of the product

A harness nobody can install is not the number one anything. So:

- **It ships as a gem** (`gem install truffle`), versioned semantically, with a
  changelog and a clear upgrade story.
- **Hosting projects can adopt it cleanly**: a `truffle init`, a config layout, a
  memory file, and **migrations** for on-disk state so a project that keeps its
  own sessions and memory can upgrade safely.
- **Compaction works in real life**, not just in theory — tested against real
  conversations, preserving a locked head of non-removable context.

## How we get there

Slowly and steadily. One focused, tested increment per cron run, each shipped
green with the changelog and roadmap updated in the same commit. The brain file
(`docs/BRAIN.md`) carries continuity between runs: what is done, what is next,
what was learned, and a set of locked invariants that never get dropped. The
roadmap (`ROADMAP.md`) carries the ordered slices. This file carries the
destination.

The measure of success is not commit count. It is whether Truffle is the harness
a serious Ruby developer would actually choose — faithful to pi, complete,
dependency-free, and genuinely good.
