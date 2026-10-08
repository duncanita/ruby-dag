# frozen_string_literal: true

module DAG::Testing::StorageContract
  module EventLog
    include Helpers

    def test_contract_append_event_stamps_monotonic_sequence
      storage = build_contract_storage
      workflow_id = contract_create_workflow(storage)

      first = storage.append_event(
        workflow_id: workflow_id,
        event: contract_event(type: :workflow_started, workflow_id: workflow_id)
      )
      second = storage.append_event(
        workflow_id: workflow_id,
        event: contract_event(type: :workflow_completed, workflow_id: workflow_id)
      )

      assert_equal 1, first.seq
      assert_equal 2, second.seq
      assert_equal [first, second], storage.read_events(workflow_id: workflow_id)
    end

    def test_contract_read_events_filters_after_seq_and_limit
      storage = build_contract_storage
      workflow_id = contract_create_workflow(storage)
      first = storage.append_event(
        workflow_id: workflow_id,
        event: contract_event(type: :workflow_started, workflow_id: workflow_id)
      )
      storage.append_event(workflow_id: workflow_id, event: contract_event(type: :node_started, workflow_id: workflow_id))
      storage.append_event(workflow_id: workflow_id, event: contract_event(type: :workflow_completed, workflow_id: workflow_id))

      filtered = storage.read_events(workflow_id: workflow_id, after_seq: first.seq, limit: 1)

      assert_equal 1, filtered.size
      assert_equal :node_started, filtered.first.type
    end

    def test_contract_event_type_presence_and_last_sequence_without_log_materialization
      storage = build_contract_storage
      workflow_id = contract_create_workflow(storage)
      assert_nil storage.last_event_seq(workflow_id: workflow_id)
      refute storage.event_type_seen?(workflow_id: workflow_id, type: :workflow_started)

      first = storage.append_event(workflow_id: workflow_id,
        event: contract_event(type: :mutation_applied, workflow_id: workflow_id))
      assert_equal first.seq, storage.last_event_seq(workflow_id: workflow_id)
      refute storage.event_type_seen?(workflow_id: workflow_id, type: :workflow_started)

      started = storage.append_event(workflow_id: workflow_id,
        event: contract_event(type: :workflow_started, workflow_id: workflow_id))
      assert storage.event_type_seen?(workflow_id: workflow_id, type: :workflow_started)
      assert_equal started.seq, storage.last_event_seq(workflow_id: workflow_id)
    end
  end
end
