# AGENTS.md

Conventions for an automated contributor (or a human using one) working in this
repository. This file is the working agreement; the design intent lives in
`ROADMAP.md` and the API in `README.md`.

## What Truffle is

A complete agent harness for Ruby, built from scratch: the loop that turns a
language model into a tool-using agent, growing toward skills, commands,
sessions, and memory. It is a faithful, from-scratch port of
[pi](https://github.com/earendil-works/pi). The North Star is
[NORTH_STAR.md](NORTH_STAR.md). There are no runtime gem dependencies; every
provider is hand-written.

## Layout

- `lib/truffle.rb` — top-level API (`Truffle.agent`, `Truffle.tool`, `Truffle.provider`).
- `lib/truffle/agent.rb` — the agent loop. The heart of the project. Keep it
  readable.
- `lib/truffle/tool.rb`, `toolbox.rb` — the tool DSL and a named tool collection.
- `lib/truffle/message.rb`, `response.rb` — value objects.
- `lib/truffle/providers/` — the provider seam and concrete providers. Everything
  outside this directory must stay provider-agnostic.
- `test/` — minitest. The default suite is offline; one test hits OpenAI and
  skips without `OPENAI_API_KEY`.

## Working agreement

1. **Pick one roadmap item.** Open `ROADMAP.md`, take the next unchecked item,
   and do only that. Read pi's real source for that slice before you write Ruby.
   Do not bundle items.
2. **Make incremental progress and keep it shippable.** A green, smaller change
   beats a large, half-finished one. Commit at a working checkpoint.
3. **Write tests first where practical**, and never weaken existing tests to get
   green. If a test is genuinely wrong, fix it and say why in the commit.
4. **Do not hard-code to the tests.** Solve the general problem; the tests check
   it, they do not define it.
5. **Keep the offline suite offline.** No network in the default `rake test`.
6. **Run the suite before committing**: `rake test` (or `script/rb rake test`
   on a host without local Ruby). Do not commit red.
7. **Update docs in the same commit**: `CHANGELOG.md` under "Unreleased," and
   check off the `ROADMAP.md` item you finished.
8. **Stay provider-agnostic.** New provider-specific code goes under
   `lib/truffle/providers/`. The agent must never assume a provider.
9. **Dependency discipline.** A new runtime dependency needs a real reason. The
   core stays buildable on the standard library.

## Commit and PR style

- Small, focused commits with a clear subject line in the imperative mood.
- PR body: what changed and why, the roadmap item or issue it addresses, and how
  it was tested.
- Be transparent about AI involvement; do not impersonate a human reviewer.

## Secrets

Never commit an API key or any secret. The OpenAI key is read from the
`OPENAI_API_KEY` environment variable at runtime only. Tests must skip rather
than fail when it is absent.
