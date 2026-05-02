# frozen_string_literal: true

require "securerandom"

require_relative "../../dag"

module DAG
  module Testing
  end
end

module DAG::Testing::StorageContract
  BEHAVIOR_GROUPS = {
    G1: "workflow create/load/current revision",
    G2: "atomic workflow state transition plus optional event append",
    G3: "begin/commit attempt one-shot semantics",
    G4: "deterministic canonical predecessor result selection",
    G5: "atomic effect reservation and idempotency conflict rollback",
    G6: "effect claim/lease ownership and stale lease protection",
    G7: "terminal effect completion and waiting-node release",
    G8: "atomic workflow retry and retry-budget enforcement",
    G9: "revision append CAS plus workflow-state guard",
    G10: "durable event ordering and filtering",
    G11: "immutable/fresh returned values",
    G12: "standard error/failure vocabulary",
    G13: "no consumer-specific semantics in storage contract"
  }.freeze

  module Helpers
    def contract_definition
      DAG::Workflow::Definition.new
        .add_node(:a, type: :passthrough)
        .add_node(:b, type: :passthrough)
        .add_edge(:a, :b)
    end

    def contract_runtime_profile(max_workflow_retries: 0)
      DAG::RuntimeProfile[
        durability: :durable,
        max_attempts_per_node: 3,
        max_workflow_retries: max_workflow_retries,
        event_bus_kind: :null,
        metadata: {}
      ]
    end

    def contract_create_workflow(storage, definition: contract_definition, id: SecureRandom.uuid, runtime_profile: contract_runtime_profile)
      storage.create_workflow(
        id: id,
        initial_definition: definition,
        initial_context: {seed: 1},
        runtime_profile: runtime_profile
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

    def contract_begin_attempt(storage, workflow_id, node_id, attempt_number: 1, revision: 1, expected_node_state: :pending)
      storage.begin_attempt(
        workflow_id: workflow_id,
        revision: revision,
        node_id: node_id,
        expected_node_state: expected_node_state,
        attempt_number: attempt_number
      )
    end
  end
end

require_relative "storage_contract/workflow_lifecycle"
require_relative "storage_contract/revision_cas"
require_relative "storage_contract/attempt_atomicity"
require_relative "storage_contract/event_log"
require_relative "storage_contract/effects"
require_relative "storage_contract/retry"
require_relative "storage_contract/error_vocabulary"
require_relative "storage_contract/consumer_boundary"

module DAG::Testing::StorageContract
  module All
    include WorkflowLifecycle
    include RevisionCAS
    include AttemptAtomicity
    include EventLog
    include Effects
    include Retry
    include ErrorVocabulary
    include ConsumerBoundary
  end
end
