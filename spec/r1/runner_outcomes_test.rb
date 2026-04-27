# frozen_string_literal: true

require_relative "../test_helper"

class RunnerOutcomesTest < Minitest::Test
  def test_waiting_step_pauses_workflow
    storage = DAG::Adapters::Memory::Storage.new
    waiting_class = Class.new(DAG::Step::Base) do
      def call(_input)
        DAG::Waiting[reason: :external, not_before_ms: 1_700_000_000_000]
      end
    end
    registry = DAG::StepTypeRegistry.new
    registry.register(name: :wait, klass: waiting_class, fingerprint_payload: {v: 1})
    registry.register(name: :passthrough, klass: DAG::BuiltinSteps::Passthrough, fingerprint_payload: {v: 1})
    registry.freeze!

    runner = build_runner(storage: storage, registry: registry)
    definition = DAG::Workflow::Definition.new
      .add_node(:a, type: :wait)
      .add_node(:b, type: :passthrough)
      .add_edge(:a, :b)
    workflow_id = create_workflow(storage, definition)

    result = runner.call(workflow_id)
    assert_equal :waiting, result.state
    assert_equal :waiting, node_state(storage, workflow_id, :a)
  end

  def test_proposed_mutations_pause_workflow
    storage = DAG::Adapters::Memory::Storage.new
    rep_graph = DAG::ReplacementGraph[
      graph: DAG::Graph.new.tap { |g| g.add_node(:b_prime) }.freeze,
      entry_node_ids: [:b_prime],
      exit_node_ids: [:b_prime]
    ]
    mutation = DAG::ProposedMutation[
      kind: :replace_subtree,
      target_node_id: :b,
      replacement_graph: rep_graph
    ]
    pausing_class = Class.new(DAG::Step::Base) do
      define_method(:call) do |_input|
        DAG::Success[value: nil, context_patch: {}, proposed_mutations: [mutation]]
      end
    end
    registry = DAG::StepTypeRegistry.new
    registry.register(name: :propose, klass: pausing_class, fingerprint_payload: {v: 1})
    registry.freeze!

    runner = build_runner(storage: storage, registry: registry)
    definition = DAG::Workflow::Definition.new.add_node(:a, type: :propose)
    workflow_id = create_workflow(storage, definition)

    result = runner.call(workflow_id)
    assert_equal :paused, result.state
  end

  def test_step_returning_non_result_becomes_step_bad_return_failure
    storage = DAG::Adapters::Memory::Storage.new
    bogus_class = Class.new(DAG::Step::Base) do
      def call(_input) = "not a result"
    end
    registry = DAG::StepTypeRegistry.new
    registry.register(name: :bogus, klass: bogus_class, fingerprint_payload: {v: 1})
    registry.freeze!

    runner = build_runner(storage: storage, registry: registry)
    workflow_id = create_workflow(storage, DAG::Workflow::Definition.new.add_node(:a, type: :bogus))

    result = runner.call(workflow_id)
    assert_equal :failed, result.state
    attempt = storage.list_attempts(workflow_id: workflow_id, node_id: :a).last
    assert_equal :step_bad_return, attempt[:result].error[:code]
  end

  def test_step_raising_standard_error_becomes_step_raised_failure
    storage = DAG::Adapters::Memory::Storage.new
    raising_class = Class.new(DAG::Step::Base) do
      def call(_input) = raise "boom"
    end
    registry = DAG::StepTypeRegistry.new
    registry.register(name: :raiser, klass: raising_class, fingerprint_payload: {v: 1})
    registry.freeze!

    runner = build_runner(storage: storage, registry: registry)
    workflow_id = create_workflow(storage, DAG::Workflow::Definition.new.add_node(:a, type: :raiser))

    result = runner.call(workflow_id)
    assert_equal :failed, result.state
    attempt = storage.list_attempts(workflow_id: workflow_id, node_id: :a).last
    assert_equal :step_raised, attempt[:result].error[:code]
    assert_equal "RuntimeError", attempt[:result].error[:error_class]
  end

  def test_paused_workflow_can_be_resumed_back_to_running
    storage = DAG::Adapters::Memory::Storage.new
    runner = build_runner(storage: storage)
    workflow_id = create_workflow(storage, simple_definition)
    storage.transition_workflow_state(id: workflow_id, from: :pending, to: :paused)

    result = runner.resume(workflow_id)
    assert_equal :completed, result.state
  end

  def test_call_rejects_workflow_in_invalid_starting_state
    storage = DAG::Adapters::Memory::Storage.new
    runner = build_runner(storage: storage)
    workflow_id = create_workflow(storage, simple_definition)
    storage.transition_workflow_state(id: workflow_id, from: :pending, to: :running)

    assert_raises(DAG::StaleStateError) { runner.call(workflow_id) }
  end

  def test_call_rejects_paused_workflow
    storage = DAG::Adapters::Memory::Storage.new
    runner = build_runner(storage: storage)
    workflow_id = create_workflow(storage, simple_definition)
    storage.transition_workflow_state(id: workflow_id, from: :pending, to: :paused)

    assert_raises(DAG::StaleStateError) { runner.call(workflow_id) }
  end

  # Roadmap §R1 line 565: when the per-layer loop exits with no eligible
  # nodes and the workflow is incomplete (no node :waiting), workflow goes
  # to :failed with diagnostic, not :waiting.
  def test_finalize_fails_with_diagnostic_when_no_eligible_and_incomplete
    storage = DAG::Adapters::Memory::Storage.new
    event_bus = DAG::Adapters::Memory::EventBus.new
    runner = build_runner(storage: storage, event_bus: event_bus)
    workflow_id = create_workflow(storage, simple_definition)

    # Park `a` in :running. Mimics an orphan attempt left over by an unclean
    # crash: under #call (no abort_running_attempts) the runner finds no
    # eligible nodes (`:running` is not eligible, and `b`'s predecessor is
    # not `:committed`) and no node is `:waiting`, so finalize must surface
    # `:failed` with the diagnostic rather than silently succeed.
    storage.transition_node_state(workflow_id: workflow_id, revision: 1, node_id: :a, from: :pending, to: :running)

    result = runner.call(workflow_id)
    assert_equal :failed, result.state
    failure_event = event_bus.events.reverse_each.find { |e| e.type == :workflow_failed }
    assert_equal :no_eligible_but_incomplete, failure_event.payload[:diagnostic]
  end
end
