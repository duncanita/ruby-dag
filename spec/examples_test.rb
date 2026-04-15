# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "tmpdir"

class ExamplesTest < Minitest::Test
  def test_workflow_runner_example_executes_successfully
    stdout, stderr, status = run_example("examples/workflow_runner.rb")

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

  def test_checkpoint_resume_example_executes_successfully
    stdout, stderr, status = run_example("examples/checkpoint_resume.rb")

    assert status.success?, <<~MSG
      expected checkpoint_resume example to succeed
      stdout:
      #{stdout}
      stderr:
      #{stderr}
    MSG

    assert_includes stdout, "=== First Run ==="
    assert_includes stdout, "=== Second Run (resume) ==="
    assert_includes stdout, "Fetch calls: 1"
  end

  private

  def run_example(path)
    env = {
      "TMPDIR" => Dir.tmpdir,
      "HOME" => ENV.fetch("HOME", Dir.pwd)
    }

    Open3.capture3(env,
      Gem.ruby, "-Ilib", path,
      chdir: File.expand_path("..", __dir__))
  end
end
