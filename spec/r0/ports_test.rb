# frozen_string_literal: true

require_relative "../test_helper"

class R0PortsTest < Minitest::Test
  STORAGE_METHODS = {
    create_workflow: {id: "x", initial_definition: nil, initial_context: {}, runtime_profile: nil},
    load_workflow: {id: "x"},
    transition_workflow_state: {id: "x", from: :pending, to: :running},
    append_revision: {id: "x", parent_revision: 1, definition: nil, invalidated_node_ids: [], event: nil},
    load_revision: {id: "x", revision: 1},
    load_current_definition: {id: "x"},
    load_node_states: {workflow_id: "x", revision: 1},
    transition_node_state: {workflow_id: "x", revision: 1, node_id: :a, from: :pending, to: :running},
    begin_attempt: {workflow_id: "x", revision: 1, node_id: :a, attempt_number: 1, expected_node_state: :pending},
    commit_attempt: {attempt_id: "x", result: nil, node_state: :committed, event: nil},
    abort_running_attempts: {workflow_id: "x"},
    list_attempts: {workflow_id: "x"},
    count_attempts: {workflow_id: "x", revision: 1, node_id: :a},
    append_event: {workflow_id: "x", event: nil},
    read_events: {workflow_id: "x"}
  }.freeze

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
