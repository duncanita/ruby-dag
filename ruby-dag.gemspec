# frozen_string_literal: true

require_relative "lib/dag/version"

Gem::Specification.new do |spec|
  spec.name = "ruby-dag"
  spec.version = DAG::VERSION
  spec.authors = ["Riccardo Lucatuorto (GnuDuncan)"]
  spec.summary = "Lightweight DAG workflow runner in pure Ruby"
  spec.description = "Define multi-step workflows as YAML or build them programmatically. Automatic dependency resolution and pluggable parallel execution (Threads, Processes, Ractors, or Sequential). Zero runtime dependencies."
  spec.homepage = "https://github.com/duncanita/ruby-dag"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0"

  spec.files = Dir["lib/**/*.rb", "bin/*", "README.md", "LICENSE"]
  spec.bindir = "bin"
  spec.executables = ["dag"]

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
end
