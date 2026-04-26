# frozen_string_literal: true

require_relative "../test_helper"

class ResumeInFlightAttemptTest < Minitest::Test
  def test_resume_aborts_running_attempt_and_resets_node_to_pending
    storage = DAG::Adapters::Memory::Storage.new
    call_log = []
    registry = registry_with_logging_step(call_log)
    workflow_id = create_workflow(storage, logging_definition)

    storage.transition_workflow_state(id: workflow_id, from: :pending, to: :running)
    stale_attempt_id = storage.begin_attempt(
      workflow_id: workflow_id,
      revision: 1,
      node_id: :a,
      expected_node_state: :pending
    )

    result = build_runner(storage: storage, registry: registry).resume(workflow_id)

    assert_equal :completed, result.state
    assert_equal [:a], call_log
    assert_equal :committed, node_state(storage, workflow_id, :a)

    attempts = storage.list_attempts(workflow_id: workflow_id, revision: 1, node_id: :a)
    assert_equal [stale_attempt_id, "#{workflow_id}/2"], attempts.map { |attempt| attempt[:attempt_id] }
    assert_equal [:aborted, :committed], attempts.map { |attempt| attempt[:state] }
    assert_equal 1, attempts.last[:attempt_number]
  end

  def test_resume_does_not_auto_rerun_waiting_attempts
    storage = DAG::Adapters::Memory::Storage.new
    call_count = 0
    registry = waiting_registry { call_count += 1 }
    workflow_id = create_workflow(storage, waiting_definition)

    first = build_runner(storage: storage, registry: registry).call(workflow_id)
    second = build_runner(storage: storage, registry: registry).resume(workflow_id)

    assert_equal :waiting, first.state
    assert_equal :waiting, second.state
    assert_equal 1, call_count
    assert_equal :waiting, node_state(storage, workflow_id, :a)
  end

  private

  def logging_definition
    DAG::Workflow::Definition.new.add_node(:a, type: :logging)
  end

  def waiting_definition
    DAG::Workflow::Definition.new.add_node(:a, type: :wait)
  end

  def waiting_registry(&block)
    wait_class = Class.new(DAG::Step::Base) do
      define_method(:call) do |_input|
        block.call
        DAG::Waiting[reason: :external]
      end
    end
    registry = DAG::StepTypeRegistry.new
    registry.register(name: :wait, klass: wait_class, fingerprint_payload: {v: 1})
    registry.freeze!
    registry
  end
end
