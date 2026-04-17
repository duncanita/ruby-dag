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

  def test_ttl_expiry_example_executes_successfully
    stdout, stderr, status = run_example("examples/ttl_expiry.rb")

    assert status.success?, <<~MSG
      expected ttl_expiry example to succeed
      stdout:
      #{stdout}
      stderr:
      #{stderr}
    MSG

    assert_includes stdout, "=== First Run ==="
    assert_includes stdout, "Output: run-1"
    assert_includes stdout, "=== Second Run (reuse within ttl) ==="
    assert_includes stdout, "=== Third Run (ttl expired) ==="
    assert_includes stdout, "Output: run-2"
    assert_includes stdout, "Calls: 2"
    assert_includes stdout, "Stale cause: ttl_expired"
  end

  def test_versioned_dependency_inputs_example_executes_successfully
    stdout, stderr, status = run_example("examples/versioned_dependency_inputs.rb")

    assert status.success?, <<~MSG
      expected versioned_dependency_inputs example to succeed
      stdout:
      #{stdout}
      stderr:
      #{stderr}
    MSG

    assert_includes stdout, "=== First Run ==="
    assert_includes stdout, "Source: scan-1"
    assert_includes stdout, "=== Second Run ==="
    assert_includes stdout, "Latest value: scan-2"
    assert_includes stdout, "First value: scan-1"
    assert_includes stdout, 'History: ["scan-1", "scan-2"]'
    assert_includes stdout, "Source calls: 2"
    assert_includes stdout, "Stored versions: [1, 2]"
  end

  def test_missing_requested_version_waiting_example_executes_successfully
    stdout, stderr, status = run_example("examples/missing_requested_version_waiting.rb")

    assert status.success?, <<~MSG
      expected missing_requested_version_waiting example to succeed
      stdout:
      #{stdout}
      stderr:
      #{stderr}
    MSG

    assert_includes stdout, "=== Cross-Workflow First Run ==="
    assert_includes stdout, "Status: waiting"
    assert_includes stdout, "=== Cross-Workflow Second Run ==="
    assert_includes stdout, "Output: external-v2"
    assert_includes stdout, "=== Local Historical Version ==="
    assert_includes stdout, "Error code: missing_dependency_version"
  end

  def test_logging_middleware_example_executes_successfully
    stdout, stderr, status = run_example("examples/logging_middleware.rb")

    assert status.success?, <<~MSG
      expected logging_middleware example to succeed
      stdout:
      #{stdout}
      stderr:
      #{stderr}
    MSG

    assert_includes stdout, '"event":"starting"'
    assert_includes stdout, '"event":"finished"'
    assert_includes stdout, "=== Structured Log Summary ==="
    assert_includes stdout, "Status: completed"
    assert_includes stdout, "Events captured: 4"
    assert_includes stdout, "Final output: PAYLOAD"
    assert_includes stdout, "Formatted sample: finished transform attempt=1 step_type=ruby status=ok"
  end

  def test_logging_middleware_failures_example_executes_successfully
    stdout, stderr, status = run_example("examples/logging_middleware_failures.rb")

    assert status.success?, <<~MSG
      expected logging_middleware_failures example to succeed
      stdout:
      #{stdout}
      stderr:
      #{stderr}
    MSG

    assert_includes stdout, '"status":"fail"'
    assert_includes stdout, '"event":"raised"'
    assert_includes stdout, "=== Failure Result Summary ==="
    assert_includes stdout, "Step error code: invalid_payload"
    assert_includes stdout, "=== Raised Exception Summary ==="
    assert_includes stdout, "Step error code: step_raised"
    assert_includes stdout, "Raised error class: RuntimeError"
    assert_includes stdout, "Raised error message: middleware kaboom for explode"
    assert_includes stdout, "Formatted sample: raised explode attempt=1 step_type=ruby error_class=RuntimeError error_message=middleware kaboom for explode"
  end

  def test_event_middleware_example_executes_successfully
    stdout, stderr, status = run_example("examples/event_middleware.rb")

    assert status.success?, <<~MSG
      expected event_middleware example to succeed
      stdout:
      #{stdout}
      stderr:
      #{stderr}
    MSG

    assert_includes stdout, "=== Event Summary ==="
    assert_includes stdout, "Status: completed"
    assert_includes stdout, "Events captured: 2"
    assert_includes stdout, "Event names: anomaly_detected, high_priority"
    assert_includes stdout, "First payload severity: high"
    assert_includes stdout, "First metadata source: detector"
    assert_includes stdout, "Second payload priority: high"
    assert_includes stdout, "Node path: monitor"
  end

  def test_nested_event_middleware_example_executes_successfully
    stdout, stderr, status = run_example("examples/nested_event_middleware.rb")

    assert status.success?, <<~MSG
      expected nested_event_middleware example to succeed
      stdout:
      #{stdout}
      stderr:
      #{stderr}
    MSG

    assert_includes stdout, "=== Nested Event Summary ==="
    assert_includes stdout, "Status: completed"
    assert_includes stdout, "Events captured: 1"
    assert_includes stdout, "Event names: child_ready"
    assert_includes stdout, "Event node path: process.analyze"
    assert_includes stdout, "Event payload source: child"
    assert_includes stdout, "Event payload normalized: HELLO"
    assert_includes stdout, "Event metadata scope: nested"
    assert_includes stdout, "Event metadata producer: analyze"
  end

  def test_invalidation_cascade_example_executes_successfully
    stdout, stderr, status = run_example("examples/invalidation_cascade.rb")

    assert status.success?, <<~MSG
      expected invalidation_cascade example to succeed
      stdout:
      #{stdout}
      stderr:
      #{stderr}
    MSG

    assert_includes stdout, "=== First Run ==="
    assert_includes stdout, "=== Invalidate source ==="
    assert_includes stdout, "Stale nodes: [[:source], [:transform]]"
    assert_includes stdout, "Stale cause code: upstream_changed"
    assert_includes stdout, "Stale cause source: coordinator"
    assert_includes stdout, "=== Second Run (recompute stale nodes) ==="
    assert_includes stdout, "Source calls: 2"
    assert_includes stdout, "Transform calls: 2"
  end

  def test_nested_invalidation_cascade_example_executes_successfully
    stdout, stderr, status = run_example("examples/nested_invalidation_cascade.rb")

    assert status.success?, <<~MSG
      expected nested_invalidation_cascade example to succeed
      stdout:
      #{stdout}
      stderr:
      #{stderr}
    MSG

    assert_includes stdout, "=== First Run ==="
    assert_includes stdout, "=== Invalidate nested node ==="
    assert_includes stdout, "Invalidated nodes: [[:process], [:process, :publish], [:process, :transform]]"
    assert_includes stdout, "Stale cause code: manual_invalidation"
    assert_includes stdout, "Stale cause source: operator"
    assert_includes stdout, "Stale cause reason: repair"
    assert_includes stdout, "=== Second Run ==="
    assert_includes stdout, "Transform calls: 2"
    assert_includes stdout, "Publish calls: 2"
  end

  def test_yaml_nested_invalidation_cascade_example_executes_successfully
    stdout, stderr, status = run_example("examples/yaml_nested_invalidation_cascade.rb")

    assert status.success?, <<~MSG
      expected yaml_nested_invalidation_cascade example to succeed
      stdout:
      #{stdout}
      stderr:
      #{stderr}
    MSG

    assert_includes stdout, "=== First Run ==="
    assert_includes stdout, "=== Invalidate YAML nested node ==="
    assert_includes stdout, "Invalidated nodes: [[:process], [:process, :publish], [:process, :transform]]"
    assert_includes stdout, "Stale cause code: upstream_changed"
    assert_includes stdout, "Stale cause source: yaml_reloader"
    assert_includes stdout, "Stale cause dependency: transform"
    assert_includes stdout, "=== Second Run ==="
    assert_includes stdout, "Transform calls: 2"
    assert_includes stdout, "Publish calls: 2"
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
