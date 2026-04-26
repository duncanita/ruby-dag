# frozen_string_literal: true

require_relative "lib/dag/version"

Gem::Specification.new do |spec|
  spec.name = "ruby-dag"
  spec.version = DAG::VERSION
  spec.authors = ["Riccardo Lucatuorto (GnuDuncan)"]
  spec.summary = "Deterministic DAG execution kernel in pure Ruby"
  spec.description = "Immutable workflow definitions executed by a frozen Runner against injected ports for storage, event bus, clock, fingerprint, ids, and serialization. Zero runtime dependencies."
  spec.homepage = "https://github.com/duncanita/ruby-dag"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4"

  spec.files = Dir["lib/**/*.rb", "README.md", "CONTRACT.md", "CHANGELOG.md", "LICENSE"]

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
end
