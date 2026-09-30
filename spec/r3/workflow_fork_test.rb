# frozen_string_literal: true

require_relative "../test_helper"

class WorkflowForkTest < Minitest::Test
  def test_runner_uses_inherited_projection_without_reexecuting_committed_node
    storage = DAG::Adapters::Memory::Storage.new
    source_id = create_workflow(storage, simple_definition, initial_context: {base: 2})
    attempt_id = storage.begin_attempt(workflow_id: source_id, revision: 1,
      node_id: :a, expected_node_state: :pending, attempt_number: 1)
    storage.commit_attempt(attempt_id: attempt_id,
      result: DAG::Success[value: :done, context_patch: {seed: 7}],
      node_state: :committed,
      event: DAG::Event[type: :node_committed, workflow_id: source_id,
        revision: 1, node_id: :a, attempt_id: attempt_id, at_ms: 0, payload: {}])
    target_id = "#{source_id}-fork"
    storage.fork_workflow(source_id: source_id, source_revision: 1, new_id: target_id)

    assert_equal :completed, build_runner(storage: storage).call(target_id).state
    assert_empty storage.list_attempts(workflow_id: target_id, node_id: :a)
    result = storage.list_attempts(workflow_id: target_id, node_id: :b).first[:result]
    assert_equal({base: 2, seed: 7}, result.value)

    replacement = simple_definition.add_node(:c, type: :noop)
    storage.append_revision(id: source_id, parent_revision: 1, definition: replacement,
      invalidated_node_ids: [], event: nil)
    assert_equal [:a, :b], storage.load_current_definition(id: target_id).nodes.to_a.sort
    assert_equal({a: :committed, b: :committed},
      storage.load_node_states(workflow_id: target_id, revision: 1))
  end

  def test_fork_crash_is_all_or_nothing
    [:before, :after, :none].each do |phase|
      storage = DAG::Adapters::Memory::CrashableStorage.new(
        crash_on: {method: :fork_workflow}.merge(phase => true)
      )
      source_id = create_workflow(storage, simple_definition)
      commit_node(storage, source_id, 1, :a)
      target_id = "#{source_id}-fork"

      if phase == :none
        assert_equal 1, storage.fork_workflow(source_id: source_id,
          source_revision: 1, new_id: target_id)[:revision]
      else
        assert_raises(DAG::Adapters::Memory::SimulatedCrash) do
          storage.fork_workflow(source_id: source_id, source_revision: 1, new_id: target_id)
        end
      end

      recovered = storage.snapshot_to_healthy
      if phase == :before
        assert_raises(DAG::UnknownWorkflowError) { recovered.load_workflow(id: target_id) }
      else
        assert_equal :committed, recovered.load_node_states(workflow_id: target_id, revision: 1)[:a]
        assert_equal 1, recovered.load_workflow(id: target_id)[:current_revision]
      end
    end
  end
end
