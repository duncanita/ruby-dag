# frozen_string_literal: true

module DAG
  # Durable kernel event. Frozen `Data` value with a JSON-safe payload.
  # `type` must be one of {Event::TYPES}. `seq` is assigned by storage at
  # append time (`nil` until then).
  # @api public
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

      # Build an `Event` with default `seq: nil`, `node_id: nil`,
      # `attempt_id: nil`, `payload: {}`.
      # @return [Event]
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
      DAG::Validation.member!(
        type,
        DAG::Event::TYPES,
        "type",
        message: "invalid event type: #{type.inspect}"
      )
      DAG.json_safe!(payload, "$root.payload")

      super(
        seq: seq,
        type: type,
        workflow_id: DAG.frozen_copy(workflow_id),
        revision: revision,
        node_id: DAG.frozen_copy(node_id),
        attempt_id: DAG.frozen_copy(attempt_id),
        at_ms: at_ms,
        payload: DAG.frozen_copy(payload)
      )
    end
  end

  # Closed set of event type symbols emitted by the kernel.
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
