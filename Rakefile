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

desc "Run tests with coverage report"
task :coverage do
  ENV["COVERAGE"] = "1"
  Rake::Task[:test].invoke
end

task default: [:test, :standard, :rubocop]
