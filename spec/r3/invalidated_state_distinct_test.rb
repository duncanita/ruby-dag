# frozen_string_literal: true

require_relative "../test_helper"

# Roadmap v3.4 §7.4 NODE_STATES makes :invalidated a distinct node state per
# revision (line 964–971), §R3 line 727/750/756 require that nodes whose
# upstream output changed be marked :invalidated (not :pending) immediately
# after a mutation. The mandatory test on line 2493 of the roadmap asserts
# `:invalidated` right after `mutation_service.apply`. This test mirrors that
# contract and follows up with a resume to verify the runner re-executes
# invalidated nodes back to :committed.
class R3InvalidatedStateDistinctTest < Minitest::Test
  def test_invalidate_marks_descendants_invalidated_then_resume_recommits
    storage = DAG::Adapters::Memory::Storage.new
    workflow_id = create_committed_workflow(storage, three_node_chain(:a, :b, :c))
    runner = build_runner(storage: storage)
    service = DAG::MutationService.new(
      storage: storage,
      event_bus: DAG::Adapters::Null::EventBus.new,
      clock: DAG::Adapters::Stdlib::Clock.new
    )

    service.apply(
      workflow_id: workflow_id,
      mutation: DAG::ProposedMutation[kind: :invalidate, target_node_id: :b],
      expected_revision: 1
    )

    states_after_apply = storage.load_node_states(workflow_id: workflow_id, revision: 2)
    assert_equal :committed, states_after_apply[:a]
    assert_equal :invalidated, states_after_apply[:b]
    assert_equal :invalidated, states_after_apply[:c]

    result = runner.resume(workflow_id)

    assert_equal :completed, result.state
    states_after_resume = storage.load_node_states(workflow_id: workflow_id, revision: 2)
    assert_equal :committed, states_after_resume[:a]
    assert_equal :committed, states_after_resume[:b]
    assert_equal :committed, states_after_resume[:c]
  end

  def test_replace_subtree_marks_preserved_impacted_invalidated
    storage = DAG::Adapters::Memory::Storage.new
    workflow_id = create_committed_workflow(storage, diamond_definition)
    service = DAG::MutationService.new(
      storage: storage,
      event_bus: DAG::Adapters::Null::EventBus.new,
      clock: DAG::Adapters::Stdlib::Clock.new
    )

    service.apply(
      workflow_id: workflow_id,
      mutation: DAG::ProposedMutation[
        kind: :replace_subtree,
        target_node_id: :b,
        replacement_graph: DAG::ReplacementGraph[
          graph: DAG::Graph.new.add_node(:b_prime).freeze,
          entry_node_ids: [:b_prime],
          exit_node_ids: [:b_prime]
        ]
      ],
      expected_revision: 1
    )

    states = storage.load_node_states(workflow_id: workflow_id, revision: 2)
    assert_equal :committed, states[:a]
    assert_equal :committed, states[:c]
    assert_equal :pending, states[:b_prime], "newly introduced replacement node must be :pending"
    assert_equal :invalidated, states[:d], "preserved-impacted node must be :invalidated, not :pending"
    refute_includes states.keys, :b
  end

  def test_invalidated_node_attempt_number_restarts_on_new_revision
    storage = DAG::Adapters::Memory::Storage.new
    workflow_id = create_committed_workflow(storage, three_node_chain(:a, :b, :c))
    runner = build_runner(storage: storage)
    service = DAG::MutationService.new(
      storage: storage,
      event_bus: DAG::Adapters::Null::EventBus.new,
      clock: DAG::Adapters::Stdlib::Clock.new
    )

    service.apply(
      workflow_id: workflow_id,
      mutation: DAG::ProposedMutation[kind: :invalidate, target_node_id: :b],
      expected_revision: 1
    )
    runner.resume(workflow_id)

    rev2_b_attempts = storage.list_attempts(workflow_id: workflow_id, revision: 2, node_id: :b)
    assert_equal [1], rev2_b_attempts.map { |a| a[:attempt_number] },
      "revision 2 attempt_number for re-executed :invalidated node must restart at 1"
  end

  private

  def diamond_definition
    DAG::Workflow::Definition.new
      .add_node(:a, type: :passthrough)
      .add_node(:b, type: :passthrough)
      .add_node(:c, type: :passthrough)
      .add_node(:d, type: :passthrough)
      .add_edge(:a, :b)
      .add_edge(:a, :c)
      .add_edge(:b, :d)
      .add_edge(:c, :d)
  end
end
