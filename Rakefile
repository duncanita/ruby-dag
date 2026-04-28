# frozen_string_literal: true

require "rake/testtask"
require "standard/rake"
require "rubocop/rake_task"

Rake::TestTask.new(:test) do |t|
  t.libs << "spec"
  t.pattern = "spec/**/*_test.rb"
end

# Custom DAG cops only — style is owned by Standard. See `.rubocop.yml`.
RuboCop::RakeTask.new(:rubocop) do |t|
  t.options = ["--display-cop-names"]
end

# YARD documentation gate. Two-part check:
#
# 1. `yard doc --fail-on-warning` actually parses the public surface and
#    fails on malformed tags, undefined cross-references, broken
#    `(see ...)` chains, and any other YARD warning. Without this, a
#    typo'd `@param` name or a stale `(see Ports::Storage#renamed)`
#    would silently degrade the docs while `yard stats` still reports
#    100%.
# 2. `yard stats` enforces a hard floor on the documented percentage so
#    a new public method cannot land without docs. The threshold is
#    pinned at the current state (locked in by the v1.0 readiness gate)
#    rather than a soft floor — any regression must either be repaired
#    or call out the loosening explicitly here.
YARD_DOC_THRESHOLD = 99.0

desc "Run YARD docs gate (no warnings + documentation >= #{YARD_DOC_THRESHOLD}%)"
task :yard do
  sh "bundle exec yard doc --no-output --no-progress --fail-on-warning"

  output = `bundle exec yard stats`
  puts output
  abort "YARD failed to produce stats" unless $?.success?
  match = output.match(/(\d+\.\d+)% documented/)
  abort "could not parse YARD stats output" unless match

  pct = match[1].to_f
  if pct < YARD_DOC_THRESHOLD
    abort "YARD documentation #{pct}% is below the #{YARD_DOC_THRESHOLD}% threshold"
  end
end

desc "Run tests with coverage report"
task :coverage do
  ENV["COVERAGE"] = "1"
  Rake::Task[:test].invoke
end

task default: [:test, :standard, :rubocop, :yard]
