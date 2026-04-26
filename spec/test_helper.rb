# frozen_string_literal: true

if ENV["COVERAGE"]
  require "simplecov"
  SimpleCov.start do
    add_filter "/spec/"
    enable_coverage :branch
    # Line coverage stays at 100% (alpha-stage hard gate). Branch coverage
    # is 90% during R1 — defensive guard branches that R1 doesn't yet
    # exercise will be tightened to 100% as part of the Release gate
    # (#74). Don't lower this further without an explicit reason.
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

TEST_TMPDIR = File.expand_path(ENV.fetch("TMPDIR", "~/.tmp/ruby-dag-tests"))
FileUtils.mkdir_p(TEST_TMPDIR)
ENV["TMPDIR"] = TEST_TMPDIR

module Minitest
  class Test
    include RunnerFactory
    include WorkflowBuilders
    include StepHelpers
  end
end
