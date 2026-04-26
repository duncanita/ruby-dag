# frozen_string_literal: true

module DAG
  Event = Data.define(
    :seq,
    :type,
    :workflow_id,
    :revision,
    :node_id,
    :attempt_id,
    :at_ms,
    :payload
  ) do
    class << self
      remove_method :[]

      def [](type:, workflow_id:, revision:, at_ms:, seq: nil, node_id: nil, attempt_id: nil, payload: {})
        new(
          type: type,
          workflow_id: workflow_id,
          revision: revision,
          at_ms: at_ms,
          seq: seq,
          node_id: node_id,
          attempt_id: attempt_id,
          payload: payload
        )
      end
    end

    def initialize(type:, workflow_id:, revision:, at_ms:, seq: nil, node_id: nil, attempt_id: nil, payload: {})
      raise ArgumentError, "invalid event type: #{type.inspect}" unless DAG::Event::TYPES.include?(type)
      DAG.json_safe!(payload, "$root.payload")

      super(
        seq: seq,
        type: type,
        workflow_id: workflow_id,
        revision: revision,
        node_id: node_id,
        attempt_id: attempt_id,
        at_ms: at_ms,
        payload: DAG.deep_freeze(DAG.deep_dup(payload))
      )
    end
  end

  Event::TYPES = %i[
    workflow_started
    node_started
    node_committed
    node_waiting
    node_failed
    workflow_paused
    workflow_waiting
    workflow_completed
    workflow_failed
    mutation_applied
  ].freeze
end
