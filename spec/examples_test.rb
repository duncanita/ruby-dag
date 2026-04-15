# frozen_string_literal: true

require_relative "test_helper"
require "open3"

class ExamplesTest < Minitest::Test
  include TestHelpers

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

  def test_schedule_metadata_roundtrip_example_executes_successfully
    stdout, stderr, status = run_example("examples/schedule_metadata_roundtrip.rb")

    assert status.success?, <<~MSG
      expected schedule_metadata_roundtrip example to succeed
      stdout:
      #{stdout}
      stderr:
      #{stderr}
    MSG

    assert_includes stdout, "=== Dumped Schedule Metadata ==="
    assert_includes stdout, "2026-04-15T10:00:00Z"
    assert_includes stdout, "2026-04-15T11:00:00Z"
    assert_includes stdout, "0 * * * *"
    assert_includes stdout, "=== Loaded Schedule Metadata ==="
    assert_includes stdout, "Status: waiting"
    assert_includes stdout, "Status: completed"
    assert_includes stdout, "Output: payload"
  end

  def test_graph_basics_example_executes_successfully
    stdout, stderr, status = run_example("examples/graph_basics.rb")

    assert status.success?, <<~MSG
      expected graph_basics example to succeed
      stdout:
      #{stdout}
      stderr:
      #{stderr}
    MSG

    assert_includes stdout, "=== Graph Overview ==="
    assert_includes stdout, "=== Topological Ordering ==="
    assert_includes stdout, "fetch -> store?  true"
    assert_includes stdout, "=== Cycle Detection ==="
    assert_includes stdout, "Caught:"
    assert_includes stdout, "=== Empty Graph ==="
  end

  def test_builder_and_immutability_example_executes_successfully
    stdout, stderr, status = run_example("examples/builder_and_immutability.rb")

    assert status.success?, <<~MSG
      expected builder_and_immutability example to succeed
      stdout:
      #{stdout}
      stderr:
      #{stderr}
    MSG

    assert_includes stdout, "=== Builder ==="
    assert_includes stdout, "Frozen? true"
    assert_includes stdout, "=== Dup (mutable copy) ==="
    assert_includes stdout, "=== Copy-on-Write (with_node / with_edge) ==="
    assert_includes stdout, "Same structure: true"
    assert_includes stdout, "=== Validation ==="
  end

  private

  def run_example(path)
    Open3.capture3(example_env,
      Gem.ruby, "-Ilib", path,
      chdir: File.expand_path("..", __dir__))
  end
end
