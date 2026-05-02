# frozen_string_literal: true

require_relative "../test_helper"

class R3PlanVersionInvariantsTest < Minitest::Test
  def test_plan_version_names_workflow_revision_coordinate
    version = DAG::PlanVersion[workflow_id: "wf-1", revision: 2]

    assert_equal "wf-1", version.workflow_id
    assert_equal 2, version.revision
    assert version.frozen?
    assert_equal({workflow_id: "wf-1", revision: 2}, version.to_h)
  end

  def test_plan_version_defensively_freezes_workflow_id
    workflow_id = +"wf-1"
    version = DAG::PlanVersion[workflow_id: workflow_id, revision: 2]

    workflow_id << "-mutated"

    assert_equal "wf-1", version.workflow_id
    assert version.workflow_id.frozen?
  end

  def test_plan_version_returns_immutable_workflow_id
    version = DAG::PlanVersion[workflow_id: +"wf-1", revision: 2]

    assert_raises(FrozenError) do
      version.workflow_id << "-mutated"
    end
  end

  def test_plan_version_rejects_empty_workflow_id
    assert_raises(ArgumentError) do
      DAG::PlanVersion[workflow_id: "", revision: 1]
    end
  end

  def test_plan_version_rejects_non_positive_revision
    assert_raises(ArgumentError) do
      DAG::PlanVersion[workflow_id: "wf-1", revision: 0]
    end
  end

  def test_runner_uses_explicit_carry_forward_results_without_rerunning_preserved_nodes
    storage = DAG::Adapters::Memory::Storage.new
    workflow_id = create_committed_workflow(storage, simple_definition)
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
    captured_contexts = {}

    result = build_runner(
      storage: storage,
      registry: registry_that_captures_context(captured_contexts)
    ).resume(workflow_id)

    assert_equal :completed, result.state
    assert_equal({a: true}, captured_contexts.fetch(:b))
    assert_empty storage.list_attempts(workflow_id: workflow_id, revision: 2, node_id: :a)
    assert_equal 1, storage.list_attempts(workflow_id: workflow_id, revision: 2, node_id: :b).size
  end

  def test_loading_older_revision_returns_pre_mutation_graph
    storage = DAG::Adapters::Memory::Storage.new
    original = replaceable_definition
    original_hash = original.to_h
    workflow_id = create_committed_workflow(storage, original)
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

    assert_equal original_hash, storage.load_revision(id: workflow_id, revision: 1).to_h
    refute storage.load_revision(id: workflow_id, revision: 2).has_node?(:b)
    assert storage.load_revision(id: workflow_id, revision: 2).has_node?(:b_prime)
  end

  private

  def registry_that_captures_context(captured_contexts)
    registry = DAG::StepTypeRegistry.new
    capture_class = Class.new(DAG::Step::Base) do
      define_method(:call) do |input|
        captured_contexts[input.node_id] = input.context.to_h
        DAG::Success[value: input.node_id, context_patch: {input.node_id => true}]
      end
    end
    registry.register(name: :passthrough, klass: capture_class, fingerprint_payload: {v: 1})
    registry.freeze!
    registry
  end

  def replaceable_definition
    DAG::Workflow::Definition.new
      .add_node(:a, type: :passthrough)
      .add_node(:b, type: :passthrough)
      .add_node(:c, type: :passthrough)
      .add_edge(:a, :b)
      .add_edge(:b, :c)
  end
end
