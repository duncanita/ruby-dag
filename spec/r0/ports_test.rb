# frozen_string_literal: true

require_relative "../test_helper"

class R0PortsTest < Minitest::Test
  STORAGE_METHODS = {
    create_workflow: {id: "x", initial_definition: nil, initial_context: {}, runtime_profile: nil},
    load_workflow: {id: "x"},
    transition_workflow_state: {id: "x", from: :pending, to: :running},
    append_revision: {id: "x", parent_revision: 1, definition: nil, invalidated_node_ids: [], event: nil},
    append_revision_if_workflow_state: {
      id: "x",
      allowed_states: [:pending],
      parent_revision: 1,
      definition: nil,
      invalidated_node_ids: [],
      event: nil
    },
    load_revision: {id: "x", revision: 1},
    load_current_definition: {id: "x"},
    load_node_states: {workflow_id: "x", revision: 1},
    transition_node_state: {workflow_id: "x", revision: 1, node_id: :a, from: :pending, to: :running},
    begin_attempt: {workflow_id: "x", revision: 1, node_id: :a, expected_node_state: :pending, attempt_number: 1},
    commit_attempt: {attempt_id: "x", result: nil, node_state: :committed, event: nil},
    list_effects_for_node: {workflow_id: "x", revision: 1, node_id: :a},
    list_effects_for_attempt: {attempt_id: "x"},
    claim_ready_effects: {limit: 1, owner_id: "worker", lease_ms: 1, now_ms: 1},
    mark_effect_succeeded: {effect_id: "x", owner_id: "worker", result: {}, external_ref: nil, now_ms: 1},
    mark_effect_failed: {effect_id: "x", owner_id: "worker", error: {}, retriable: true, not_before_ms: nil, now_ms: 1},
    renew_effect_lease: {effect_id: "x", owner_id: "worker", until_ms: 2, now_ms: 1},
    complete_effect_succeeded: {effect_id: "x", owner_id: "worker", result: {}, external_ref: nil, now_ms: 1},
    complete_effect_failed: {effect_id: "x", owner_id: "worker", error: {}, retriable: false, not_before_ms: nil, now_ms: 1},
    release_nodes_satisfied_by_effect: {effect_id: "x", now_ms: 1},
    abort_running_attempts: {workflow_id: "x"},
    list_attempts: {workflow_id: "x"},
    list_committed_results_for_predecessors: {workflow_id: "x", revision: 1, predecessors: []},
    count_attempts: {workflow_id: "x", revision: 1, node_id: :a},
    append_event: {workflow_id: "x", event: nil},
    read_events: {workflow_id: "x"},
    prepare_workflow_retry: {id: "x"}
  }.freeze

  ROOT = File.expand_path("../..", __dir__)

  def test_storage_port_method_list_matches_documented_contract
    assert_equal STORAGE_METHODS.keys.sort, DAG::Ports::Storage.public_instance_methods(false).sort
  end

  def test_storage_port_public_methods_document_return_shapes
    source = File.read(File.join(ROOT, "lib/dag/ports/storage.rb"))

    STORAGE_METHODS.each_key do |method_name|
      method_documentation = source.match(/((?:\s*#.*\n)+)\s*def #{method_name}\(/)
      refute_nil method_documentation, "#{method_name} should have a documentation block"
      assert_includes method_documentation[1], "@return", "#{method_name} should document its return shape"
    end
  end

  def test_runner_does_not_parse_storage_error_messages
    runner = File.read(File.join(ROOT, "lib/dag/runner.rb"))
    storage_error_rescue = /rescue\s+(?:DAG::)?(?:StaleStateError|StaleRevisionError|ConcurrentMutationError|WorkflowRetryExhaustedError)[^\n]*=>\s*(\w+)(?:.|\n){0,200}\1\.message/

    refute_match storage_error_rescue, runner
  end

  def test_storage_port_every_method_raises_port_not_implemented
    adapter = Class.new { include DAG::Ports::Storage }.new
    STORAGE_METHODS.each do |method, args|
      assert_raises(DAG::PortNotImplementedError, "#{method} should raise") { adapter.public_send(method, **args) }
    end
  end

  def test_event_bus_port_methods_raise_port_not_implemented
    adapter = Class.new { include DAG::Ports::EventBus }.new
    assert_raises(DAG::PortNotImplementedError) { adapter.publish(:event) }
    assert_raises(DAG::PortNotImplementedError) { adapter.subscribe { |_| } }
  end

  def test_fingerprint_port_raises_port_not_implemented
    adapter = Class.new { include DAG::Ports::Fingerprint }.new
    assert_raises(DAG::PortNotImplementedError) { adapter.compute({}) }
  end

  def test_clock_port_methods_raise_port_not_implemented
    adapter = Class.new { include DAG::Ports::Clock }.new
    assert_raises(DAG::PortNotImplementedError) { adapter.now }
    assert_raises(DAG::PortNotImplementedError) { adapter.now_ms }
    assert_raises(DAG::PortNotImplementedError) { adapter.monotonic_ms }
  end

  def test_id_generator_port_raises_port_not_implemented
    adapter = Class.new { include DAG::Ports::IdGenerator }.new
    assert_raises(DAG::PortNotImplementedError) { adapter.call }
  end

  def test_serializer_port_raises_port_not_implemented
    adapter = Class.new { include DAG::Ports::Serializer }.new
    assert_raises(DAG::PortNotImplementedError) { adapter.dump({}) }
    assert_raises(DAG::PortNotImplementedError) { adapter.load("{}") }
  end
end
