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

    registry = DAG::StepTypeRegistry.new
    registry.register(name: :a_step, klass: a_class, fingerprint_payload: {v: 1})
    registry.register(name: :b_step, klass: b_class, fingerprint_payload: {v: 1})
    registry.register(name: :sink_step, klass: context_dump_step_class, fingerprint_payload: {v: 1})
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

  def test_effective_context_uses_highest_committed_attempt_independent_of_storage_order
    storage_class = Class.new(DAG::Adapters::Memory::Storage) do
      def initialize(seed:)
        super()
        @random = Random.new(seed)
      end

      def list_attempts(workflow_id:, revision: nil, node_id: nil)
        attempts = super
        return attempts unless node_id == :a

        [
          attempt_record(workflow_id, revision, 2, "attempt-b", "newer"),
          attempt_record(workflow_id, revision, 1, "attempt-z", "older")
        ].shuffle(random: @random)
      end

      def list_committed_results_for_predecessors(workflow_id:, revision:, predecessors:)
        return super unless predecessors.map(&:to_sym).include?(:a)

        attempts = [
          attempt_record(workflow_id, revision, 2, "attempt-b", "newer"),
          attempt_record(workflow_id, revision, 1, "attempt-z", "older")
        ].shuffle(random: @random)
        {a: attempts.max_by { |attempt| [attempt.fetch(:attempt_number), attempt.fetch(:attempt_id).to_s] }.fetch(:result)}
      end

      private

      def attempt_record(workflow_id, revision, attempt_number, attempt_id, value)
        {
          attempt_id: attempt_id,
          workflow_id: workflow_id,
          revision: revision,
          node_id: :a,
          attempt_number: attempt_number,
          state: :committed,
          result: DAG::Success[value: value, context_patch: {shared: value}]
        }
      end
    end

    registry = DAG::StepTypeRegistry.new
    registry.register(name: :passthrough, klass: DAG::BuiltinSteps::Passthrough, fingerprint_payload: {v: 1})
    registry.register(name: :sink_step, klass: context_dump_step_class, fingerprint_payload: {v: 1})
    registry.freeze!

    definition = DAG::Workflow::Definition.new
      .add_node(:a, type: :passthrough)
      .add_node(:c, type: :sink_step)
      .add_edge(:a, :c)

    observed = Array.new(5) do |seed|
      storage = storage_class.new(seed: seed)
      workflow_id = create_workflow(storage, definition)
      build_runner(storage: storage, registry: registry).call(workflow_id)

      sink_attempt = storage.list_attempts(workflow_id: workflow_id, node_id: :c).last
      sink_attempt[:result].value[:shared]
    end
    assert_equal ["newer"], observed.uniq
  end

  def test_effective_context_uses_batched_committed_result_lookup_when_available
    storage_class = Class.new(DAG::Adapters::Memory::Storage) do
      attr_reader :batch_calls, :list_attempt_calls

      def initialize
        super
        @batch_calls = 0
        @list_attempt_calls = 0
      end

      def list_committed_results_for_predecessors(...)
        @batch_calls += 1
        super
      end

      def list_attempts(...)
        @list_attempt_calls += 1
        super
      end
    end
    storage = storage_class.new
    runner = build_runner(storage: storage)
    workflow_id = create_workflow(storage, fan_out_fan_in(:a, [:b, :c], :d), initial_context: {seed: 7})

    runner.call(workflow_id)

    assert_operator storage.batch_calls, :>, 0
    assert_equal 0, storage.list_attempt_calls
  end

  private

  def context_dump_step_class
    @context_dump_step_class ||= Class.new(DAG::Step::Base) do
      def call(input)
        DAG::Success[value: input.context.to_h, context_patch: input.context.to_h]
      end
    end
  end
end
