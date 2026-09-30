# frozen_string_literal: true

require_relative "../test_helper"

class RunnerEventHistoryTest < Minitest::Test
  class CountingStorage < DAG::Adapters::Memory::Storage
    attr_reader :full_log_reads

    def initialize
      super
      @full_log_reads = 0
    end

    def read_events(**kwargs)
      @full_log_reads += 1
      super
    end
  end

  def test_call_and_resume_avoid_full_log_reads_with_pre_run_events
    storage = CountingStorage.new
    runner = build_runner(storage: storage)
    [:call, :resume].each do |method|
      workflow_id = create_workflow(storage, DAG::Workflow::Definition.new)
      1_000.times do
        storage.append_event(workflow_id: workflow_id,
          event: DAG::Event[type: :mutation_applied, workflow_id: workflow_id,
            revision: 1, at_ms: 0, payload: {blob: "x" * 128}])
      end
      storage.transition_workflow_state(id: workflow_id, from: :pending, to: :paused) if method == :resume

      result = runner.public_send(method, workflow_id)
      assert_equal :completed, result.state
      assert_equal 1_002, result.last_event_seq
      assert_equal 0, storage.full_log_reads
      assert storage.event_type_seen?(workflow_id: workflow_id, type: :workflow_started)
    end
  end

  def test_older_memory_snapshot_builds_type_index_before_next_append
    state = DAG::Adapters::Memory::StorageState.fresh_state
    storage = DAG::Adapters::Memory::Storage.new(initial_state: state)
    workflow_id = create_workflow(storage, DAG::Workflow::Definition.new)
    storage.append_event(workflow_id: workflow_id,
      event: DAG::Event[type: :workflow_started, workflow_id: workflow_id,
        revision: 1, at_ms: 0, payload: {}])
    state.delete(:event_types_seen)

    storage.append_event(workflow_id: workflow_id,
      event: DAG::Event[type: :mutation_applied, workflow_id: workflow_id,
        revision: 1, at_ms: 0, payload: {}])
    assert storage.event_type_seen?(workflow_id: workflow_id, type: :workflow_started)
    assert storage.event_type_seen?(workflow_id: workflow_id, type: :mutation_applied)
    assert_equal 2, storage.last_event_seq(workflow_id: workflow_id)
  end
end
