# frozen_string_literal: true

require_relative "../test_helper"

class ScopedStepInputTest < Minitest::Test
  def test_runner_exposes_runtime_snapshot_with_current_coordinates
    storage = DAG::Adapters::Memory::Storage.new
    observed = []
    registry = DAG::StepTypeRegistry.new
    capture_class = Class.new(DAG::Step::Base) do
      define_method(:call) do |input|
        observed << input.runtime_snapshot
        DAG::Success[value: :ok, context_patch: {}]
      end
    end
    registry.register(name: :capture, klass: capture_class, fingerprint_payload: {v: 1})
    registry.freeze!
    definition = DAG::Workflow::Definition.new.add_node(:capture, type: :capture)
    workflow_id = create_workflow(storage, definition)

    result = build_runner(storage: storage, registry: registry).call(workflow_id)

    assert_equal :completed, result.state
    snapshot = observed.fetch(0)
    assert_instance_of DAG::RuntimeSnapshot, snapshot
    assert_equal workflow_id, snapshot.workflow_id
    assert_equal 1, snapshot.revision
    assert_equal :capture, snapshot.node_id
    assert_equal "#{workflow_id}/1", snapshot.attempt_id
    assert_equal 1, snapshot.attempt_number
    assert_equal DAG::PlanVersion[workflow_id: workflow_id, revision: 1], snapshot.plan_version
    assert_equal({}, snapshot.predecessors)
    assert_equal({}, snapshot.effects)
  end

  def test_runtime_snapshot_predecessors_use_canonical_committed_results
    storage_class = Class.new(DAG::Adapters::Memory::Storage) do
      def list_committed_results_for_predecessors(workflow_id:, revision:, predecessors:)
        return super unless predecessors.map(&:to_sym).include?(:source)

        attempts = [
          attempt_record(workflow_id, revision, 2, "attempt-b", "newer"),
          attempt_record(workflow_id, revision, 1, "attempt-z", "older")
        ].reverse
        {source: attempts.max_by { |attempt| [attempt.fetch(:attempt_number), attempt.fetch(:attempt_id).to_s] }.fetch(:result)}
      end

      private

      def attempt_record(workflow_id, revision, attempt_number, attempt_id, value)
        {
          attempt_id: attempt_id,
          workflow_id: workflow_id,
          revision: revision,
          node_id: :source,
          attempt_number: attempt_number,
          state: :committed,
          result: DAG::Success[
            value: {label: value},
            context_patch: {shared: value},
            metadata: {canonical: value == "newer"}
          ]
        }
      end
    end
    storage = storage_class.new
    observed_snapshots = []
    observed_contexts = []
    registry = registry_with_sink(observed_snapshots, observed_contexts)
    definition = DAG::Workflow::Definition.new
      .add_node(:source, type: :source)
      .add_node(:sink, type: :sink)
      .add_edge(:source, :sink)
    workflow_id = create_workflow(storage, definition, initial_context: {seed: 1})

    result = build_runner(storage: storage, registry: registry).call(workflow_id)

    assert_equal :completed, result.state
    snapshot = observed_snapshots.fetch(0)
    assert_equal({label: "newer"}, snapshot.predecessors.fetch(:source).fetch(:value))
    assert_equal({shared: "newer"}, snapshot.predecessors.fetch(:source).fetch(:context_patch))
    assert_equal({canonical: true}, snapshot.predecessors.fetch(:source).fetch(:metadata))
    assert_equal({seed: 1, shared: "newer"}, observed_contexts.fetch(0))
  end

  def test_runtime_snapshot_is_deep_frozen_and_fresh_copied
    metadata = {
      workflow_id: "wf",
      revision: 1,
      attempt_id: "wf/1",
      predecessors: {
        source: {
          value: {items: ["original"]},
          context_patch: {shared: "source"},
          metadata: {tags: ["stable"]}
        }
      },
      effects: {
        "effect:one" => {status: :succeeded, result: {values: [1]}}
      },
      runtime_metadata: {labels: ["public"]}
    }
    input = DAG::StepInput[
      context: {local: {items: ["context"]}},
      node_id: :node,
      attempt_number: 1,
      metadata: metadata
    ]

    snapshot = input.runtime_snapshot
    metadata[:predecessors][:source][:value][:items] << "mutated"
    metadata[:effects]["effect:one"][:result][:values] << 2
    metadata[:runtime_metadata][:labels] << "mutated"

    assert_equal ["original"], snapshot.predecessors.fetch(:source).fetch(:value).fetch(:items)
    assert_equal [1], snapshot.effects.fetch("effect:one").fetch(:result).fetch(:values)
    assert_equal ["public"], snapshot.metadata.fetch(:labels)
    assert snapshot.frozen?
    assert snapshot.predecessors.frozen?
    assert snapshot.predecessors.fetch(:source).fetch(:value).fetch(:items).frozen?
    assert snapshot.effects.fetch("effect:one").fetch(:result).fetch(:values).frozen?
    assert snapshot.metadata.fetch(:labels).frozen?
  end

  def test_runtime_snapshot_rejects_non_json_safe_extension_metadata
    error = assert_raises(ArgumentError) do
      DAG::RuntimeSnapshot[
        workflow_id: "wf",
        revision: 1,
        node_id: :node,
        attempt_id: "wf/1",
        attempt_number: 1,
        metadata: {bad: Object.new}
      ]
    end

    assert_match(/non JSON-safe value/, error.message)
  end

  def test_runtime_snapshot_predecessors_use_current_revision_projection_for_preserved_nodes
    storage = DAG::Adapters::Memory::Storage.new
    observed_snapshots = []
    observed_contexts = []
    registry = registry_with_sink(observed_snapshots, observed_contexts)
    definition = DAG::Workflow::Definition.new
      .add_node(:source, type: :source)
      .add_node(:sink, type: :sink)
      .add_edge(:source, :sink)
    workflow_id = create_workflow(storage, definition)
    commit_node(storage, workflow_id, 1, :source)
    storage.transition_workflow_state(id: workflow_id, from: :pending, to: :paused)

    storage.append_revision(
      id: workflow_id,
      parent_revision: 1,
      definition: definition,
      invalidated_node_ids: [:sink],
      event: nil
    )
    result = build_runner(storage: storage, registry: registry).resume(workflow_id)

    assert_equal :completed, result.state
    assert_empty storage.list_attempts(workflow_id: workflow_id, revision: 2, node_id: :source)
    snapshot = observed_snapshots.fetch(0)
    assert_equal 2, snapshot.revision
    assert_equal({value: :source, context_patch: {source: true}, metadata: {}}, snapshot.predecessors.fetch(:source))
    assert_equal({source: true}, observed_contexts.fetch(0))
  end

  def test_runtime_snapshot_effects_do_not_leak_across_nodes
    storage = DAG::Adapters::Memory::Storage.new
    intent = effect_intent(key: "node-a")
    observed_b_effects = []
    registry = DAG::StepTypeRegistry.new
    wait_class = Class.new(DAG::Step::Base) do
      define_method(:call) do |_input|
        DAG::Waiting[reason: :effect_pending, proposed_effects: [intent]]
      end
    end
    capture_class = Class.new(DAG::Step::Base) do
      define_method(:call) do |input|
        observed_b_effects << input.runtime_snapshot.effects
        DAG::Success[value: :b, context_patch: {}]
      end
    end
    registry.register(name: :wait, klass: wait_class, fingerprint_payload: {v: 1})
    registry.register(name: :capture, klass: capture_class, fingerprint_payload: {v: 1})
    registry.freeze!
    definition = DAG::Workflow::Definition.new
      .add_node(:a, type: :wait)
      .add_node(:b, type: :capture)
    workflow_id = create_workflow(storage, definition)

    result = build_runner(storage: storage, registry: registry).call(workflow_id)

    assert_equal :waiting, result.state
    assert_empty observed_b_effects.fetch(0)
    assert_equal 1, storage.list_effects_for_node(workflow_id: workflow_id, revision: 1, node_id: :a).size
  end

  def test_runtime_snapshot_effects_are_scoped_to_current_node_revision
    storage = DAG::Adapters::Memory::Storage.new
    snapshots = []
    intent = effect_intent(key: "approval")
    registry = DAG::StepTypeRegistry.new
    klass = Class.new(DAG::Step::Base) do
      define_method(:call) do |input|
        snapshots << input.runtime_snapshot
        if snapshots.size == 1
          DAG::Waiting[reason: :effect_pending, proposed_effects: [intent]]
        else
          DAG::Success[value: :rerun, context_patch: {}]
        end
      end
    end
    registry.register(name: :effectful, klass: klass, fingerprint_payload: {v: 1})
    registry.freeze!
    definition = DAG::Workflow::Definition.new.add_node(:node, type: :effectful)
    workflow_id = create_workflow(storage, definition)

    first = build_runner(storage: storage, registry: registry).call(workflow_id)
    assert_equal :waiting, first.state
    effect = storage.list_effects_for_node(workflow_id: workflow_id, revision: 1, node_id: :node).fetch(0)
    claimed = storage.claim_ready_effects(limit: 1, owner_id: "worker", lease_ms: 500, now_ms: 1_000)
    assert_equal [effect.id], claimed.map(&:id)

    storage.append_revision(
      id: workflow_id,
      parent_revision: 1,
      definition: definition,
      invalidated_node_ids: [:node],
      event: nil
    )
    resumed = build_runner(storage: storage, registry: registry).resume(workflow_id)

    assert_equal :completed, resumed.state
    assert_equal 1, snapshots.fetch(0).revision
    assert_equal 2, snapshots.fetch(1).revision
    assert_empty snapshots.fetch(1).effects
  end

  def test_runtime_snapshot_effects_exclude_lease_and_storage_fields
    storage = DAG::Adapters::Memory::Storage.new
    snapshots = []
    intent = effect_intent(key: "done")
    registry = DAG::StepTypeRegistry.new
    klass = Class.new(DAG::Step::Base) do
      define_method(:call) do |input|
        snapshots << input.runtime_snapshot
        effect_snapshot = input.runtime_snapshot.effects[intent.ref]
        if effect_snapshot&.fetch(:status, nil) == :succeeded
          DAG::Success[value: :ok, context_patch: {}]
        else
          DAG::Waiting[reason: :effect_pending, proposed_effects: [intent]]
        end
      end
    end
    registry.register(name: :await_effect, klass: klass, fingerprint_payload: {v: 1})
    registry.freeze!
    workflow_id = create_workflow(storage, DAG::Workflow::Definition.new.add_node(:node, type: :await_effect))

    first = build_runner(storage: storage, registry: registry).call(workflow_id)
    assert_equal :waiting, first.state
    effect = storage.list_effects_for_node(workflow_id: workflow_id, revision: 1, node_id: :node).fetch(0)
    mark_effect_succeeded_and_release(storage, effect.id, result: {approved: true})
    resumed = build_runner(storage: storage, registry: registry).resume(workflow_id)

    assert_equal :completed, resumed.state
    effect_snapshot = snapshots.fetch(1).effects.fetch(intent.ref)
    assert_equal :succeeded, effect_snapshot.fetch(:status)
    assert_equal({approved: true}, effect_snapshot.fetch(:result))
    refute_includes effect_snapshot.keys, :lease_owner
    refute_includes effect_snapshot.keys, :lease_until_ms
    refute_includes effect_snapshot.keys, :created_at_ms
    refute_includes effect_snapshot.keys, :updated_at_ms
  end

  private

  def registry_with_sink(observed_snapshots, observed_contexts)
    registry = DAG::StepTypeRegistry.new
    source_class = Class.new(DAG::Step::Base) do
      def call(_input)
        DAG::Success[value: {label: "real"}, context_patch: {shared: "real"}]
      end
    end
    sink_class = Class.new(DAG::Step::Base) do
      define_method(:call) do |input|
        observed_snapshots << input.runtime_snapshot
        observed_contexts << input.context.to_h
        DAG::Success[value: :sink, context_patch: {}]
      end
    end
    registry.register(name: :source, klass: source_class, fingerprint_payload: {v: 1})
    registry.register(name: :sink, klass: sink_class, fingerprint_payload: {v: 1})
    registry.freeze!
    registry
  end

  def effect_intent(key:, payload: {value: 1})
    DAG::Effects::Intent[type: "test", key: key, payload: payload, metadata: {source: "spec"}]
  end

  def mark_effect_succeeded_and_release(storage, effect_id, result:)
    claimed = storage.claim_ready_effects(limit: 1, owner_id: "worker", lease_ms: 500, now_ms: 1_000)
    assert_equal [effect_id], claimed.map(&:id)
    storage.mark_effect_succeeded(
      effect_id: effect_id,
      owner_id: "worker",
      result: result,
      external_ref: "external-#{effect_id}",
      now_ms: 1_100
    )
    storage.release_nodes_satisfied_by_effect(effect_id: effect_id, now_ms: 1_200)
  end
end
