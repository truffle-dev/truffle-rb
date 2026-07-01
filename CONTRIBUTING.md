# Contributing to Truffle

Thanks for your interest. Truffle is meant to stay small and readable, so the bar
for changes is "does this make the agent runtime better without making it
harder to read."

## Ground rules

- **One focused change per PR.** Match a single roadmap item or fix one bug.
  Bundled PRs are hard to review and slow to land.
- **Tests stay green and the offline suite stays offline.** The default
  `rake test` must pass without any network or API key. Live provider tests must
  skip unless their key is present (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`,
  `GEMINI_API_KEY`).
- **Keep the core loop readable.** `lib/truffle/agent.rb` should remain something a
  newcomer can read top to bottom and understand.
- **Provider-agnostic above the seam.** Nothing outside `lib/truffle/providers/`
  may assume a specific provider.

## Development

```sh
script/check
```

`script/check` is the deterministic path for a clean machine with Docker. It
uses `script/rb`, installs/checks the bundle in a Docker volume, runs
`bundle exec rake test`, then runs `bundle exec rubocop`.

With a local Ruby:

```sh
bundle install
rake test            # offline suite
bundle exec rubocop
```

For live provider tests:

```sh
cp .env.local.example .env.local
# Fill in any keys you have, then:
script/rb rake test
script/rb ruby examples/calculator.rb "What is 6 times 7?"
```

When you run through `script/rb` or `script/check`, `.env.local` is loaded for
the container without printing the values. With local Ruby, export the keys or
source `.env.local` in your shell first.

Coverage is opt-in:

```sh
COVERAGE=true script/rb rake test
```

The HTML report is written under `coverage/`, and the LCOV report uploaded by CI
is written to `coverage/lcov.info`.

Refresh the committed model catalog only as an explicit maintenance step:

```sh
script/rb ruby script/refresh-models
script/rb ruby script/refresh-models --check
```

The refresh script reads `https://models.dev/api.json`, emits full cost keys for
`Model.new`, and writes `lib/truffle/models.rb`. Truffle never fetches model data
at runtime.

## Pull requests

- Reference the roadmap item or issue you are addressing.
- Add or update tests for the behavior you change.
- Update `CHANGELOG.md` under "Unreleased."
- If you complete a roadmap item, check it off in `ROADMAP.md` in the same PR.

## AI-assisted contributions

Truffle itself is developed with AI assistance, openly. AI-assisted PRs are
welcome on the same terms as any other: the code must be understood by whoever
submits it, tests must pass, and the change must be reviewable. See
[AGENTS.md](AGENTS.md) for conventions an automated contributor should follow.
