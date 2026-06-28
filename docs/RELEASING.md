# Releasing Truffle

How a new version of the `truffle` gem ships to
[rubygems.org](https://rubygems.org/gems/truffle), and how a project that depends
on it upgrades.

## Versioning

Truffle follows [Semantic Versioning](https://semver.org/). The version lives in
one place: `lib/truffle/version.rb` (`Truffle::VERSION`). The gemspec reads it,
so a release is one edit plus a build.

- **Patch** (`0.1.0 -> 0.1.1`): bug fixes, no API change.
- **Minor** (`0.1.0 -> 0.2.0`): new, backward-compatible capability (most
  roadmap slices land here while pre-1.0).
- **Major** (`0.x -> 1.0`, then `1.x -> 2.x`): a breaking change. Pre-1.0, minor
  bumps may carry breaking changes; the CHANGELOG always calls them out.

## The changelog is the contract

`CHANGELOG.md` follows [Keep a Changelog](https://keepachangelog.com/). Every
change lands with an entry under `## [Unreleased]`, grouped into `Added`,
`Changed`, `Fixed`, `Removed`. A release simply renames `Unreleased` to the new
version with today's date and opens a fresh `Unreleased` heading. The compare and
tag links at the bottom are updated in the same commit.

## Cutting a release

1. Confirm green: `./script/rb rake test`.
2. Bump `Truffle::VERSION` in `lib/truffle/version.rb`.
3. In `CHANGELOG.md`, move the `Unreleased` items under a new
   `## [X.Y.Z] - YYYY-MM-DD` heading; add the new compare/tag links.
4. Commit: `Release vX.Y.Z`.
5. Tag and push: `git tag vX.Y.Z && git push origin main --tags`.
6. Build and publish (the API key is never stored in the repo; it is supplied as
   an environment variable for the single push command and nowhere else):

   ```sh
   gem build truffle.gemspec
   GEM_HOST_API_KEY=... gem push truffle-X.Y.Z.gem
   ```

   On this VM, the build and push run inside the `ruby:3.3-slim` container with
   the key passed as `-e GEM_HOST_API_KEY` for that one command only.
7. Verify from a clean environment:
   `docker run --rm ruby:3.3-slim sh -c 'gem install truffle && ruby -e "require \"truffle\"; puts Truffle::VERSION"'`.

## How a dependent project upgrades

A project pins Truffle in its `Gemfile`:

```ruby
gem "truffle", "~> 0.1"
```

- `bundle update truffle` pulls the latest compatible version.
- The CHANGELOG is the upgrade guide: read the entries between the installed and
  target versions. Breaking changes are always flagged there.
- When a release changes on-disk state that a host project owns (sessions,
  memory; see the roadmap's adoption phase), it ships a **migration** so the
  upgrade is safe and reversible. The migration and its version are documented in
  the CHANGELOG entry for that release. Truffle never silently rewrites a
  project's saved state.

## Automation note

The daily `truffle-build-advance` run ships code, not releases. Cutting a version
and pushing to RubyGems is a deliberate step taken when a meaningful set of
changes has accumulated under `Unreleased`. Keep releases small and frequent
rather than large and rare.
