# frozen_string_literal: true

module DAG
  # Public, immutable event-log diagnostic derived from a durable DAG::Event.
  # The shape is deliberately kernel-generic: it carries workflow/revision,
  # node/attempt coordinates, event time, a normalized status, the original
  # event type, sequence, and JSON-safe payload.
  # @api public
  TraceRecord = Data.define(
    :workflow_id,
    :revision,
    :node_id,
    :attempt_id,
    :at_ms,
    :status,
    :event_type,
    :seq,
    :payload
  ) do
    class << self
      remove_method :[]

      # @param event [DAG::Event] stamped durable event
      # @return [DAG::TraceRecord]
      def from_event(event)
        DAG::Validation.instance!(event, DAG::Event, "event")
        new(
          workflow_id: event.workflow_id,
          revision: event.revision,
          node_id: event.node_id,
          attempt_id: event.attempt_id,
          at_ms: event.at_ms,
          status: DAG::TraceRecord::EVENT_STATUS.fetch(event.type),
          event_type: event.type,
          seq: event.seq,
          payload: event.payload
        )
      end

      # @return [DAG::TraceRecord]
      def [](
        workflow_id:,
        revision:,
        at_ms:,
        status:,
        event_type:,
        node_id: nil,
        attempt_id: nil,
        seq: nil,
        payload: {}
      )
        new(
          workflow_id: workflow_id,
          revision: revision,
          node_id: node_id,
          attempt_id: attempt_id,
          at_ms: at_ms,
          status: status,
          event_type: event_type,
          seq: seq,
          payload: payload
        )
      end
    end

    def initialize(
      workflow_id:,
      revision:,
      at_ms:,
      status:,
      event_type:,
      node_id: nil,
      attempt_id: nil,
      seq: nil,
      payload: {}
    )
      DAG::Validation.string!(workflow_id, "workflow_id")
      DAG::Validation.revision!(revision)
      DAG::Validation.node_id!(node_id) unless node_id.nil?
      DAG::Validation.string!(attempt_id, "attempt_id") unless attempt_id.nil?
      DAG::Validation.integer!(at_ms, "at_ms")
      DAG::Validation.member!(status, DAG::TraceRecord::STATUSES, "status", message: "invalid trace status: #{status.inspect}")
      DAG::Validation.member!(event_type, DAG::Event::TYPES, "event_type", message: "invalid event type: #{event_type.inspect}")
      DAG::Validation.optional_integer!(seq, "seq")
      DAG.json_safe!(payload, "$root.payload")

      super(
        workflow_id: DAG.frozen_copy(workflow_id),
        revision: revision,
        node_id: node_id&.to_sym,
        attempt_id: DAG.frozen_copy(attempt_id),
        at_ms: at_ms,
        status: status,
        event_type: event_type,
        seq: seq,
        payload: DAG.frozen_copy(payload)
      )
    end

    # @return [Hash] JSON-safe, deterministic public representation.
    def to_h
      DAG.frozen_copy(
        workflow_id: workflow_id,
        revision: revision,
        node_id: node_id,
        attempt_id: attempt_id,
        at_ms: at_ms,
        status: status,
        event_type: event_type,
        seq: seq,
        payload: payload
      )
    end
  end

  # Closed normalized status vocabulary used by TraceRecord.
  TraceRecord::STATUSES = %i[started success waiting failed paused completed mutation_applied].freeze

  # Mapping from durable event types to normalized trace statuses.
  TraceRecord::EVENT_STATUS = {
    workflow_started: :started,
    node_started: :started,
    node_committed: :success,
    node_waiting: :waiting,
    node_failed: :failed,
    workflow_paused: :paused,
    workflow_waiting: :waiting,
    workflow_completed: :completed,
    workflow_failed: :failed,
    mutation_applied: :mutation_applied
  }.freeze
end
