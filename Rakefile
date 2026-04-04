# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "spec"
  t.pattern = "spec/**/*_test.rb"
end

task default: :test
