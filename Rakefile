# frozen_string_literal: true

require "rake/testtask"
require "standard/rake"

Rake::TestTask.new(:test) do |t|
  t.libs << "spec"
  t.pattern = "spec/**/*_test.rb"
end

desc "Run tests with coverage report"
task :coverage do
  ENV["COVERAGE"] = "1"
  Rake::Task[:test].invoke
end

task default: [:test, :standard]
