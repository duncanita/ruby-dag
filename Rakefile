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

# YARD documentation gate. Runs `yard stats` and fails if the documented
# percentage drops below the v1.0 readiness floor. Keeps the public API
# surface from regressing into undocumented territory.
YARD_DOC_THRESHOLD = 95.0

desc "Run YARD docs gate (fail if documentation < #{YARD_DOC_THRESHOLD}%)"
task :yard do
  output = `bundle exec yard stats 2>&1`
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
