# frozen_string_literal: true

require_relative "../test_helper"

class MutationRejectionCodesTest < Minitest::Test
  def test_plan_result_factories_preserve_legacy_invalid_call
    legacy = DAG::PlanResult.invalid("readable reason")
    assert_equal "readable reason", legacy.reason
    assert_nil legacy.code
    refute legacy.valid?

    valid = DAG::PlanResult.valid(new_definition: simple_definition, invalidated_node_ids: [:a])
    assert valid.valid?
    assert_nil valid.code
    assert_raises(ArgumentError) { DAG::PlanResult.invalid("reason", code: :unknown_code) }
    assert_raises(ArgumentError) do
      DAG::PlanResult.new(valid: true, new_definition: simple_definition,
        invalidated_node_ids: [], reason: nil, code: :unknown_target)
    end
  end

  def test_editor_reports_known_rejection_codes
    definition = simple_definition
    editor = DAG::DefinitionEditor.new
    unknown = DAG::ProposedMutation[kind: :invalidate, target_node_id: :missing]
    assert_rejection(editor.plan(definition, unknown), :unknown_target)

    graph = DAG::Graph::Builder.build { |builder| builder.add_node(:a) }
    replacement = DAG::ReplacementGraph[graph: graph, entry_node_ids: [:a], exit_node_ids: [:a]]
    collision = DAG::ProposedMutation[kind: :replace_subtree, target_node_id: :b,
      replacement_graph: replacement]
    assert_rejection(editor.plan(definition, collision), :node_id_collision)

    fake = Object.new
    def fake.is_a?(klass) = klass == DAG::ProposedMutation
    def fake.kind = :other
    assert_rejection(editor.plan(definition, fake), :unsupported_mutation)
  end

  def test_structural_failures_keep_distinct_codes_when_messages_change
    definition = simple_definition
    graph = DAG::Graph::Builder.build { |builder| builder.add_node(:x) }
    replacement = DAG::ReplacementGraph[graph: graph, entry_node_ids: [:x], exit_node_ids: [:x]]
    mutation = DAG::ProposedMutation[kind: :replace_subtree, target_node_id: :b,
      replacement_graph: replacement]

    cycle_editor = DAG::DefinitionEditor.new
    def cycle_editor.build_replaced_graph(*) = raise(DAG::CycleError, "different wording")
    assert_rejection(cycle_editor.plan(definition, mutation), :would_create_cycle)

    invalid_editor = DAG::DefinitionEditor.new
    def invalid_editor.build_replaced_graph(*) = raise(ArgumentError, "another wording")
    assert_rejection(invalid_editor.plan(definition, mutation), :invalid_replacement)

    duplicate_editor = DAG::DefinitionEditor.new
    def duplicate_editor.build_replaced_graph(*) = raise(DAG::DuplicateNodeError, "collision wording")
    assert_rejection(duplicate_editor.plan(definition, mutation), :node_id_collision)
  end

  def test_valid_mutation_still_applies_through_service
    storage = DAG::Adapters::Memory::Storage.new
    workflow_id = create_workflow(storage, simple_definition)
    storage.transition_workflow_state(id: workflow_id, from: :pending, to: :paused)
    mutation = DAG::ProposedMutation[kind: :invalidate, target_node_id: :a]
    plan = DAG::DefinitionEditor.new.plan(simple_definition, mutation)
    assert plan.valid?
    assert_nil plan.code

    service = DAG::MutationService.new(storage: storage,
      event_bus: DAG::Adapters::Null::EventBus.new,
      clock: DAG::Adapters::Stdlib::Clock.new)
    assert_equal 2, service.apply(workflow_id: workflow_id, mutation: mutation, expected_revision: 1).revision

    invalid = DAG::ProposedMutation[kind: :invalidate, target_node_id: :missing]
    plan = DAG::DefinitionEditor.new.plan(storage.load_current_definition(id: workflow_id), invalid)
    assert_rejection(plan, :unknown_target)
    assert_raises(DAG::ValidationError) do
      service.apply(workflow_id: workflow_id, mutation: invalid, expected_revision: 2)
    end
  end

  private

  def assert_rejection(plan, code)
    refute plan.valid?
    assert_equal code, plan.code
    assert_kind_of String, plan.reason
    refute_empty plan.reason
  end
end
