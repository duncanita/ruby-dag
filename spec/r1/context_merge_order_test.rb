# frozen_string_literal: true

require_relative "../test_helper"

class ContextMergeOrderTest < Minitest::Test
  # A and B feed into C. Both write the same key with different values.
  # Merge order is: predecessors of C ordered by id.to_s ASCII -> B then A
  # would need to be tested... but actually [:a, :b].sort_by(&:to_s) -> [:a, :b].
  # So later predecessor wins => B's value wins.
  def test_later_predecessor_wins_on_collision
    storage = DAG::Adapters::Memory::Storage.new

    a_class = Class.new(DAG::Step::Base) do
      def call(_input) = DAG::Success[value: :from_a, context_patch: {shared: "a"}]
    end
    b_class = Class.new(DAG::Step::Base) do
      def call(_input) = DAG::Success[value: :from_b, context_patch: {shared: "b"}]
    end
    sink_class = Class.new(DAG::Step::Base) do
      def call(input)
        DAG::Success[value: input.context.to_h, context_patch: input.context.to_h]
      end
    end

    registry = DAG::StepTypeRegistry.new
    registry.register(name: :a_step, klass: a_class, fingerprint_payload: {v: 1})
    registry.register(name: :b_step, klass: b_class, fingerprint_payload: {v: 1})
    registry.register(name: :sink_step, klass: sink_class, fingerprint_payload: {v: 1})
    registry.freeze!

    runner = build_runner(storage: storage, registry: registry)

    definition = DAG::Workflow::Definition.new
      .add_node(:a, type: :a_step)
      .add_node(:b, type: :b_step)
      .add_node(:c, type: :sink_step)
      .add_edge(:a, :c)
      .add_edge(:b, :c)

    workflow_id = create_workflow(storage, definition)
    runner.call(workflow_id)

    # predecessors of c sorted by to_s = [:a, :b]; b applied last wins.
    sink_attempt = storage.list_attempts(workflow_id: workflow_id, node_id: :c).last
    assert_equal "b", sink_attempt[:result].value[:shared]
  end

  def test_100_runs_produce_identical_context_fingerprints
    fingerprint = DAG::Adapters::Stdlib::Fingerprint.new
    digests = Array.new(100) do
      storage = DAG::Adapters::Memory::Storage.new
      runner = build_runner(storage: storage)
      workflow_id = create_workflow(storage, fan_out_fan_in(:a, [:b, :c], :d), initial_context: {seed: 7})
      runner.call(workflow_id)
      sink = storage.list_attempts(workflow_id: workflow_id, node_id: :d).last
      fingerprint.compute(sink[:result].context_patch)
    end
    assert_equal 1, digests.uniq.size, "context fingerprint must be stable across 100 runs"
  end
end
