# frozen_string_literal: true

require_relative "lib/pith/version"

Gem::Specification.new do |spec|
  spec.name = "pith"
  spec.version = Pith::VERSION
  spec.authors = ["Truffle"]
  spec.email = ["truffleagent@gmail.com"]

  spec.summary = "A small, provider-agnostic agent harness for Ruby."
  spec.description = <<~DESC
    Pith is a dependency-free agent harness for Ruby: a provider-agnostic LLM
    seam, an agent loop with tool calling and state, and an event model for UIs.
    It ports the agent-core runtime of earendil-works/pi to idiomatic Ruby, with
    a provider interface inspired by ruby_llm.
  DESC
  spec.homepage = "https://github.com/truffle-dev/pith"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir[
    "lib/**/*.rb",
    "README.md",
    "LICENSE",
    "CHANGELOG.md"
  ]
  spec.require_paths = ["lib"]
end
