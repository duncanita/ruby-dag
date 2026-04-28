# frozen_string_literal: true

require_relative "../test_helper"

# Coverage tests for defensive guards across the kernel. These are paths
# that production code does not normally reach but must remain in place
# to fail loudly under a programmer error or storage corruption.
class DefensiveGuardsTest < Minitest::Test
  def test_success_rejects_non_array_proposed_mutations
    err = assert_raises(ArgumentError) do
      DAG::Success.new(value: nil, context_patch: {}, proposed_mutations: "nope", metadata: {})
    end
    assert_match(/proposed_mutations must be an Array/, err.message)
  end

  def test_run_result_factory_round_trips_through_brackets
    result = DAG::RunResult[state: :completed, last_event_seq: 1, outcome: {x: 1}]
    assert_equal :completed, result.state
    assert_equal 1, result.last_event_seq
    assert_equal({x: 1}, result.outcome)
  end

  def test_definition_editor_recovers_argument_error_into_invalid_plan
    editor = DAG::DefinitionEditor.new
    mutation = DAG::ProposedMutation[kind: :invalidate, target_node_id: :a]
    plan = editor.plan("not a definition", mutation)
    refute plan.valid?
    assert_match(/definition must be a/, plan.reason)
  end

  def test_definition_editor_handles_unsupported_mutation_kind
    editor = DAG::DefinitionEditor.new
    definition = DAG::Workflow::Definition.new.add_node(:a, type: :passthrough)

    fake = Object.new
    def fake.is_a?(klass) = klass == DAG::ProposedMutation
    def fake.kind = :nope
    def fake.target_node_id = :a

    plan = editor.plan(definition, fake)
    refute plan.valid?
    assert_match(/unsupported mutation kind/, plan.reason)
  end

  def test_definition_editor_replace_subtree_copies_internal_replacement_edges
    editor = DAG::DefinitionEditor.new
    definition = DAG::Workflow::Definition.new
      .add_node(:root, type: :passthrough)
      .add_node(:victim, type: :passthrough)
      .add_edge(:root, :victim)

    # Replacement is a 2-node chain; the editor must copy the :x -> :y edge.
    replacement_graph = DAG::Graph::Builder.build do |b|
      b.add_node(:x)
      b.add_node(:y)
      b.add_edge(:x, :y)
    end
    replacement = DAG::ReplacementGraph[
      graph: replacement_graph,
      entry_node_ids: [:x],
      exit_node_ids: [:y]
    ]
    mutation = DAG::ProposedMutation[kind: :replace_subtree, target_node_id: :victim, replacement_graph: replacement]

    plan = editor.plan(definition, mutation)
    assert plan.valid?, plan.reason
    assert plan.new_definition.has_node?(:x)
    assert plan.new_definition.has_node?(:y)
    edges = []
    plan.new_definition.each_edge { |e| edges << [e.from, e.to] }
    assert_includes edges, [:x, :y]
  end

  def test_definition_editor_replace_subtree_rejects_node_id_collision
    editor = DAG::DefinitionEditor.new
    # Chain a -> b -> c plus an independent kept node :d. Targeting :b
    # removes {b, c}; :a and :d are preserved. A replacement that
    # introduces a node named :a collides with the preserved :a.
    definition = DAG::Workflow::Definition.new
      .add_node(:a, type: :passthrough)
      .add_node(:b, type: :passthrough)
      .add_node(:c, type: :passthrough)
      .add_node(:d, type: :passthrough)
      .add_edge(:a, :b)
      .add_edge(:b, :c)

    replacement = DAG::ReplacementGraph[
      graph: DAG::Graph::Builder.build { |g| g.add_node(:a) },
      entry_node_ids: [:a],
      exit_node_ids: [:a]
    ]
    mutation = DAG::ProposedMutation[kind: :replace_subtree, target_node_id: :b, replacement_graph: replacement]

    plan = editor.plan(definition, mutation)
    refute plan.valid?
    assert_match(/collide/, plan.reason)
  end

  def test_mutation_service_rejects_workflow_in_completed_state
    kit = DAG::Toolkit.in_memory_kit(registry: default_test_registry)
    definition = DAG::Workflow::Definition.new.add_node(:a, type: :passthrough)
    id = kit.runner.id_generator.call
    kit.storage.create_workflow(
      id: id,
      initial_definition: definition,
      initial_context: {},
      runtime_profile: DAG::RuntimeProfile.default
    )
    kit.runner.call(id) # workflow goes :completed

    service = DAG::MutationService.new(storage: kit.storage, event_bus: kit.event_bus, clock: DAG::Adapters::Stdlib::Clock.new)
    mutation = DAG::ProposedMutation[kind: :invalidate, target_node_id: :a]

    err = assert_raises(DAG::StaleStateError) do
      service.apply(workflow_id: id, mutation: mutation, expected_revision: 1)
    end
    assert_match(/cannot be mutated from :completed/, err.message)
  end

  def test_storage_state_begin_attempt_rejects_non_positive_attempt_number
    storage = DAG::Adapters::Memory::Storage.new
    definition = DAG::Workflow::Definition.new.add_node(:a, type: :passthrough)
    storage.create_workflow(
      id: "wf",
      initial_definition: definition,
      initial_context: {},
      runtime_profile: DAG::RuntimeProfile.default
    )

    err = assert_raises(ArgumentError) do
      storage.begin_attempt(workflow_id: "wf", revision: 1, node_id: :a, expected_node_state: :pending, attempt_number: 0)
    end
    assert_match(/positive Integer/, err.message)
  end

  def test_storage_state_commit_attempt_rejects_node_state_drift
    storage = DAG::Adapters::Memory::Storage.new
    definition = DAG::Workflow::Definition.new.add_node(:a, type: :passthrough)
    storage.create_workflow(
      id: "wf",
      initial_definition: definition,
      initial_context: {},
      runtime_profile: DAG::RuntimeProfile.default
    )
    attempt_id = storage.begin_attempt(workflow_id: "wf", revision: 1, node_id: :a, expected_node_state: :pending, attempt_number: 1)

    # Simulate state drift: caller transitions the node out of :running
    # behind the storage's back, then tries to commit. Real storages will
    # reject this just like the in-memory adapter does.
    storage.transition_node_state(workflow_id: "wf", revision: 1, node_id: :a, from: :running, to: :pending)

    event = DAG::Event[
      type: :node_committed, workflow_id: "wf", revision: 1,
      at_ms: 0, node_id: :a, attempt_id: attempt_id, payload: {}
    ]
    err = assert_raises(DAG::StaleStateError) do
      storage.commit_attempt(
        attempt_id: attempt_id,
        result: DAG::Success[value: nil, context_patch: {}],
        node_state: :committed,
        event: event
      )
    end
    assert_match(/expected :running/, err.message)
  end

  def test_crashable_storage_attempt_context_raises_for_unknown_attempt
    storage = DAG::Adapters::Memory::CrashableStorage.new(crash_on: {method: :commit_attempt, before: true})
    fake_event = DAG::Event[
      type: :node_committed, workflow_id: "wf", revision: 1,
      at_ms: 0, node_id: :a, attempt_id: "missing", payload: {}
    ]
    assert_raises(ArgumentError) do
      storage.commit_attempt(
        attempt_id: "missing",
        result: DAG::Success[value: nil, context_patch: {}],
        node_state: :committed,
        event: fake_event
      )
    end
  end
end
