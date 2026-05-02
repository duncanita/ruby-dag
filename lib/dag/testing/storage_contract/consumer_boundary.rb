# frozen_string_literal: true

module DAG::Testing::StorageContract
  module ConsumerBoundary
    include Helpers

    def test_contract_declares_all_behavior_groups
      assert_equal (1..13).map { |index| :"G#{index}" }, DAG::Testing::StorageContract::BEHAVIOR_GROUPS.keys
      DAG::Testing::StorageContract::BEHAVIOR_GROUPS.each_value do |description|
        refute_empty description
      end
    end

    def test_contract_sources_do_not_encode_consumer_runtime_names
      contract_files = [File.expand_path("../storage_contract.rb", __dir__), *Dir[File.join(__dir__, "*.rb")]]
      forbidden_words = ["Del" + "phi", "Del" + "phic", "Run" + "Context", "SQL" + "ite", "Sql" + "ite"]
      offenders = contract_files.filter_map do |path|
        content = File.read(path)
        next unless forbidden_words.any? { |word| content.include?(word) }

        path
      end

      assert_empty offenders, "storage contract suite must stay adapter- and consumer-neutral"
    end

    def test_contract_effect_intents_are_abstract_kernel_records
      storage = build_contract_storage
      workflow_id = contract_create_workflow(storage)
      attempt_id = contract_begin_attempt(storage, workflow_id, :a)
      intent = DAG::Effects::PreparedIntent[
        workflow_id: workflow_id,
        revision: 1,
        node_id: :a,
        attempt_id: attempt_id,
        type: "external.message",
        key: "message-1",
        payload: {recipient: "ops", template: "digest"},
        payload_fingerprint: "message-fp-1",
        blocking: true,
        created_at_ms: 1_700_000_000_000
      ]

      storage.commit_attempt(
        attempt_id: attempt_id,
        result: DAG::Waiting[reason: :effect_pending],
        node_state: :waiting,
        event: contract_event(type: :node_waiting, workflow_id: workflow_id, node_id: :a, attempt_id: attempt_id),
        effects: [intent]
      )

      record = storage.list_effects_for_attempt(attempt_id: attempt_id).first
      assert_equal "external.message", record.type
      assert_equal "message-1", record.key
      assert_equal({recipient: "ops", template: "digest"}, record.payload)
      assert_equal "message-fp-1", record.payload_fingerprint
    end
  end
end
