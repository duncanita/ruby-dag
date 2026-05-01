# frozen_string_literal: true

module DAG
  module Effects
    # Durable effect snapshot returned by effect-aware storage adapters.
    # @api public
    Record = Data.define(
      :id,
      :ref,
      :workflow_id,
      :revision,
      :node_id,
      :attempt_id,
      :type,
      :key,
      :payload,
      :payload_fingerprint,
      :blocking,
      :status,
      :result,
      :error,
      :external_ref,
      :not_before_ms,
      :lease_owner,
      :lease_until_ms,
      :created_at_ms,
      :updated_at_ms,
      :metadata
    ) do
      SNAPSHOT_FIELDS = %i[
        id
        ref
        type
        key
        payload
        payload_fingerprint
        blocking
        status
        result
        error
        external_ref
        not_before_ms
        metadata
      ].freeze

      class << self
        remove_method :[]

        # `ref` is derived from `type:key`; the factory does not accept it.
        # @return [Record]
        def [](
          id:,
          workflow_id:,
          revision:,
          node_id:,
          attempt_id:,
          type:,
          key:,
          payload:,
          payload_fingerprint:,
          blocking:,
          status:,
          created_at_ms:,
          updated_at_ms:,
          result: nil,
          error: nil,
          external_ref: nil,
          not_before_ms: nil,
          lease_owner: nil,
          lease_until_ms: nil,
          metadata: {}
        )
          new(
            id: id,
            workflow_id: workflow_id,
            revision: revision,
            node_id: node_id,
            attempt_id: attempt_id,
            type: type,
            key: key,
            payload: payload,
            payload_fingerprint: payload_fingerprint,
            blocking: blocking,
            status: status,
            result: result,
            error: error,
            external_ref: external_ref,
            not_before_ms: not_before_ms,
            lease_owner: lease_owner,
            lease_until_ms: lease_until_ms,
            created_at_ms: created_at_ms,
            updated_at_ms: updated_at_ms,
            metadata: metadata
          )
        end

        # Build a durable effect snapshot from a kernel-prepared intent.
        # @param prepared_intent [DAG::Effects::PreparedIntent]
        # @return [Record]
        def from_prepared(
          id:,
          prepared_intent:,
          status:,
          updated_at_ms:,
          created_at_ms: nil,
          result: nil,
          error: nil,
          external_ref: nil,
          not_before_ms: nil,
          lease_owner: nil,
          lease_until_ms: nil,
          metadata: nil
        )
          unless prepared_intent.is_a?(DAG::Effects::PreparedIntent)
            raise ArgumentError, "prepared_intent must be DAG::Effects::PreparedIntent"
          end

          new(
            id: id,
            workflow_id: prepared_intent.workflow_id,
            revision: prepared_intent.revision,
            node_id: prepared_intent.node_id,
            attempt_id: prepared_intent.attempt_id,
            type: prepared_intent.type,
            key: prepared_intent.key,
            payload: prepared_intent.payload,
            payload_fingerprint: prepared_intent.payload_fingerprint,
            blocking: prepared_intent.blocking,
            status: status,
            created_at_ms: created_at_ms || prepared_intent.created_at_ms,
            updated_at_ms: updated_at_ms,
            result: result,
            error: error,
            external_ref: external_ref,
            not_before_ms: not_before_ms,
            lease_owner: lease_owner,
            lease_until_ms: lease_until_ms,
            metadata: metadata.nil? ? prepared_intent.metadata : metadata
          )
        end
      end

      def initialize(
        id:,
        workflow_id:,
        revision:,
        node_id:,
        attempt_id:,
        type:,
        key:,
        payload:,
        payload_fingerprint:,
        blocking:,
        status:,
        created_at_ms:,
        updated_at_ms:,
        result: nil,
        error: nil,
        external_ref: nil,
        not_before_ms: nil,
        lease_owner: nil,
        lease_until_ms: nil,
        metadata: {},
        ref: nil
      )
        # `ref:` is accepted only so `Data#with` round-trips correctly. It is
        # always recomputed from `type:key` below; user input passes through
        # `[]`, which does not expose the kwarg.
        validate_string!(id, "id")
        DAG::Effects.validate_ref_part!(type, "type")
        DAG::Effects.validate_ref_part!(key, "key")
        validate_string!(workflow_id, "workflow_id")
        validate_revision!(revision)
        validate_node_id!(node_id)
        validate_string!(attempt_id, "attempt_id")
        validate_string!(payload_fingerprint, "payload_fingerprint")
        validate_boolean!(blocking, "blocking")
        validate_status!(status)
        validate_optional_integer!(not_before_ms, "not_before_ms")
        validate_optional_integer!(lease_until_ms, "lease_until_ms")
        validate_integer!(created_at_ms, "created_at_ms")
        validate_integer!(updated_at_ms, "updated_at_ms")
        DAG.json_safe!(payload, "$root.payload")
        DAG.json_safe!(result, "$root.result")
        DAG.json_safe!(error, "$root.error")
        DAG.json_safe!(external_ref, "$root.external_ref")
        DAG.json_safe!(lease_owner, "$root.lease_owner")
        DAG.json_safe!(metadata, "$root.metadata")

        super(
          id: DAG.deep_freeze(DAG.deep_dup(id)),
          ref: DAG::Effects.ref_for(type, key),
          workflow_id: DAG.deep_freeze(DAG.deep_dup(workflow_id)),
          revision: revision,
          node_id: DAG.deep_freeze(DAG.deep_dup(node_id)),
          attempt_id: DAG.deep_freeze(DAG.deep_dup(attempt_id)),
          type: DAG.deep_freeze(DAG.deep_dup(type)),
          key: DAG.deep_freeze(DAG.deep_dup(key)),
          payload: DAG.deep_freeze(DAG.deep_dup(payload)),
          payload_fingerprint: DAG.deep_freeze(DAG.deep_dup(payload_fingerprint)),
          blocking: blocking,
          status: status,
          result: DAG.deep_freeze(DAG.deep_dup(result)),
          error: DAG.deep_freeze(DAG.deep_dup(error)),
          external_ref: DAG.deep_freeze(DAG.deep_dup(external_ref)),
          not_before_ms: not_before_ms,
          lease_owner: DAG.deep_freeze(DAG.deep_dup(lease_owner)),
          lease_until_ms: lease_until_ms,
          created_at_ms: created_at_ms,
          updated_at_ms: updated_at_ms,
          metadata: DAG.deep_freeze(DAG.deep_dup(metadata))
        )
      end

      # @return [Boolean]
      def terminal? = DAG::Effects::TERMINAL_STATUSES.include?(status)

      # Stable Hash shape injected into `StepInput#metadata[:effects]`.
      # @return [Hash]
      def to_snapshot
        DAG.deep_freeze(SNAPSHOT_FIELDS.each_with_object({}) do |field, snapshot|
          snapshot[field] = public_send(field)
        end)
      end

      private

      def validate_string!(value, label)
        raise ArgumentError, "#{label} must be String" unless value.is_a?(String)
      end

      def validate_revision!(value)
        raise ArgumentError, "revision must be a positive Integer" unless value.is_a?(Integer) && value.positive?
      end

      def validate_node_id!(value)
        return if value.is_a?(Symbol) || value.is_a?(String)

        raise ArgumentError, "node_id must be Symbol or String"
      end

      def validate_boolean!(value, label)
        return if value == true || value == false

        raise ArgumentError, "#{label} must be true or false"
      end

      def validate_status!(value)
        raise ArgumentError, "invalid effect status: #{value.inspect}" unless DAG::Effects::STATUSES.include?(value)
      end

      def validate_integer!(value, label)
        raise ArgumentError, "#{label} must be Integer" unless value.is_a?(Integer)
      end

      def validate_optional_integer!(value, label)
        return if value.nil? || value.is_a?(Integer)

        raise ArgumentError, "#{label} must be Integer or nil"
      end
    end
  end
end
