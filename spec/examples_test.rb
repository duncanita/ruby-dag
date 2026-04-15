# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "tmpdir"

class ExamplesTest < Minitest::Test
  def test_workflow_runner_example_executes_successfully
    env = {
      "TMPDIR" => Dir.tmpdir,
      "HOME" => ENV.fetch("HOME", Dir.pwd)
    }

    stdout, stderr, status = Open3.capture3(env,
      Gem.ruby, "-Ilib", "examples/workflow_runner.rb",
      chdir: File.expand_path("..", __dir__))

    assert status.success?, <<~MSG
      expected workflow_runner example to succeed
      stdout:
      #{stdout}
      stderr:
      #{stderr}
    MSG

    assert_includes stdout, "=== Manual Workflow ==="
    assert_includes stdout, "=== YAML Workflow ==="
    assert_includes stdout, "=== from_hash Workflow ==="
  end
end
