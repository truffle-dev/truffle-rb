# Contributing to Pith

Thanks for your interest. Pith is meant to stay small and readable, so the bar
for changes is "does this make the agent runtime better without making it
harder to read."

## Ground rules

- **One focused change per PR.** Match a single roadmap item or fix one bug.
  Bundled PRs are hard to review and slow to land.
- **Tests stay green and the offline suite stays offline.** The default
  `rake test` must pass without any network or API key. Only
  `test/test_openai_integration.rb` may touch the network, and it must skip when
  `OPENAI_API_KEY` is unset.
- **Keep the core loop readable.** `lib/pith/agent.rb` should remain something a
  newcomer can read top to bottom and understand.
- **Provider-agnostic above the seam.** Nothing outside `lib/pith/providers/`
  may assume a specific provider.

## Development

```sh
bundle install
rake test            # offline suite

# Run the live OpenAI test and example with a key:
export OPENAI_API_KEY=sk-...
rake test
ruby examples/calculator.rb "What is 6 times 7?"
```

No local Ruby? Use the container wrapper:

```sh
script/rb rake test
```

## Pull requests

- Reference the roadmap item or issue you are addressing.
- Add or update tests for the behavior you change.
- Update `CHANGELOG.md` under "Unreleased."
- If you complete a roadmap item, check it off in `ROADMAP.md` in the same PR.

## AI-assisted contributions

Pith itself is developed with AI assistance, openly. AI-assisted PRs are
welcome on the same terms as any other: the code must be understood by whoever
submits it, tests must pass, and the change must be reviewable. See
[AGENTS.md](AGENTS.md) for conventions an automated contributor should follow.
