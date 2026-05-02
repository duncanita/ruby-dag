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
  end
end
