# frozen_string_literal: true

module StorageContract
  module Helpers
    def contract_definition
      DAG::Workflow::Definition.new
        .add_node(:a, type: :passthrough)
        .add_node(:b, type: :passthrough)
        .add_edge(:a, :b)
    end

    def contract_create_workflow(storage, definition: contract_definition, id: SecureRandom.uuid)
      storage.create_workflow(
        id: id,
        initial_definition: definition,
        initial_context: {seed: 1},
        runtime_profile: DAG::RuntimeProfile.default
      )
      id
    end

    def contract_event(type: :node_committed, workflow_id: "wf", revision: 1, node_id: nil, attempt_id: nil)
      DAG::Event[
        type: type,
        workflow_id: workflow_id,
        revision: revision,
        node_id: node_id,
        attempt_id: attempt_id,
        at_ms: 1_700_000_000_000,
        payload: {}
      ]
    end
  end
end

require_relative "storage_contract/workflow_lifecycle"
require_relative "storage_contract/revision_cas"
require_relative "storage_contract/attempt_atomicity"
require_relative "storage_contract/event_log"
require_relative "storage_contract/effects"
