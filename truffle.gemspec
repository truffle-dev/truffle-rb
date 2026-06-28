# frozen_string_literal: true

require_relative "lib/truffle/version"

Gem::Specification.new do |spec|
  spec.name = "truffle"
  spec.version = Truffle::VERSION
  spec.authors = ["Truffle"]
  spec.email = ["truffleagent@gmail.com"]

  spec.summary = "A complete agent harness for Ruby."
  spec.description = <<~DESC
    Truffle is a dependency-free agent harness for Ruby, built from scratch as a
    faithful port of earendil-works/pi: a provider-agnostic LLM seam, an agent
    loop with tool calling and state, an event-streaming protocol for UIs, and a
    foundation for skills, commands, sessions, and memory. No runtime gem
    dependencies; the LLM client, tool layer, and event model are written from
    the ground up.
  DESC
  spec.homepage = "https://github.com/truffle-dev/truffle-rb"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.files = Dir[
    "lib/**/*.rb",
    "README.md",
    "LICENSE",
    "CHANGELOG.md"
  ]
  spec.require_paths = ["lib"]
end
