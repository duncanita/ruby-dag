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

  def test_sub_workflow_example_executes_successfully
    stdout, stderr, status = run_example("examples/sub_workflow.rb")

    assert status.success?, <<~MSG
      expected sub_workflow example to succeed
      stdout:
      #{stdout}
      stderr:
      #{stderr}
    MSG

    assert_includes stdout, "=== Programmatic Parent Workflow ==="
    assert_includes stdout, "=== Durable Programmatic Run ==="
    assert_includes stdout, "Child calls: 1"
    assert_includes stdout, "=== YAML Parent Workflow ==="
    assert_includes stdout, "=== Durable YAML Run ==="
    assert_includes stdout, "Stored YAML child output: yaml-grandchild"
  end

  def test_pause_resume_example_executes_successfully
    stdout, stderr, status = run_example("examples/pause_resume.rb")

    assert status.success?, <<~MSG
      expected pause_resume example to succeed
      stdout:
      #{stdout}
      stderr:
      #{stderr}
    MSG

    assert_includes stdout, "=== First Run (pause requested) ==="
    assert_includes stdout, "Status: paused"
    assert_includes stdout, "=== Second Run (resume) ==="
    assert_includes stdout, "Fetch calls: 1"
  end

  def test_waiting_not_before_example_executes_successfully
    stdout, stderr, status = run_example("examples/waiting_not_before.rb")

    assert status.success?, <<~MSG
      expected waiting_not_before example to succeed
      stdout:
      #{stdout}
      stderr:
      #{stderr}
    MSG

    assert_includes stdout, "=== First Run (waiting) ==="
    assert_includes stdout, "Status: waiting"
    assert_includes stdout, "=== Second Run (ready) ==="
    assert_includes stdout, "Status: completed"
    assert_includes stdout, "ready"
    assert_includes stdout, "READY"
  end

  def test_not_after_deadline_example_executes_successfully
    stdout, stderr, status = run_example("examples/not_after_deadline.rb")

    assert status.success?, <<~MSG
      expected not_after_deadline example to succeed
      stdout:
      #{stdout}
      stderr:
      #{stderr}
    MSG

    assert_includes stdout, "=== Run (expired) ==="
    assert_includes stdout, "Status: failed"
    assert_includes stdout, "Failed node: scheduled"
    assert_includes stdout, "Error code: deadline_exceeded"
    assert_includes stdout, "Scheduled calls: 0"
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
