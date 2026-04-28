# frozen_string_literal: true

if ENV["COVERAGE"]
  require "simplecov"
  SimpleCov.start do
    add_filter "/spec/"
    enable_coverage :branch
    # Line coverage is a 100% hard gate. Branch coverage floor is 90%
    # (currently sits around 91-92%). The remaining uncovered branches
    # are defensive guards behind argument-validation `unless` clauses;
    # tightening to 100% is tracked as a follow-up to the v1.0 gate
    # (see CHANGELOG 1.0.0). Don't lower these without an explicit reason.
    minimum_coverage line: 100, branch: 90
  end
end

require "fileutils"
require "minitest/autorun"
require "securerandom"
require "tempfile"
require "tmpdir"

require_relative "../lib/dag"

require_relative "support/runner_factory"
require_relative "support/workflow_builders"
require_relative "support/step_helpers"
require_relative "support/event_helpers"

TEST_TMPDIR = File.expand_path(ENV.fetch("TMPDIR", "~/.tmp/ruby-dag-tests"))
FileUtils.mkdir_p(TEST_TMPDIR)
ENV["TMPDIR"] = TEST_TMPDIR

module Minitest
  class Test
    include RunnerFactory
    include WorkflowBuilders
    include StepHelpers
    include EventHelpers
  end
end
