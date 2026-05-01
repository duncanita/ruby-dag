# frozen_string_literal: true

module DAG
  module Effects
    # Kernel-enriched form of an Intent ready to be persisted atomically with
    # an attempt commit.
    # @api public
    PreparedIntent = Data.define(
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
      :created_at_ms,
      :metadata
    ) do
      class << self
        remove_method :[]

        # `ref` is derived from `type:key`; the factory does not accept it.
        # @return [PreparedIntent]
        def [](
          workflow_id:,
          revision:,
          node_id:,
          attempt_id:,
          type:,
          key:,
          payload:,
          payload_fingerprint:,
          blocking:,
          created_at_ms:,
          metadata: {}
        )
          new(
            workflow_id: workflow_id,
            revision: revision,
            node_id: node_id,
            attempt_id: attempt_id,
            type: type,
            key: key,
            payload: payload,
            payload_fingerprint: payload_fingerprint,
            blocking: blocking,
            created_at_ms: created_at_ms,
            metadata: metadata
          )
        end

        # Build a PreparedIntent from the public step-level intent plus the
        # kernel-owned execution coordinates.
        # @param intent [DAG::Effects::Intent]
        # @return [PreparedIntent]
        def from_intent(
          intent:,
          workflow_id:,
          revision:,
          node_id:,
          attempt_id:,
          payload_fingerprint:,
          blocking:,
          created_at_ms:,
          metadata: nil
        )
          raise ArgumentError, "intent must be DAG::Effects::Intent" unless intent.is_a?(DAG::Effects::Intent)

          new(
            workflow_id: workflow_id,
            revision: revision,
            node_id: node_id,
            attempt_id: attempt_id,
            type: intent.type,
            key: intent.key,
            payload: intent.payload,
            payload_fingerprint: payload_fingerprint,
            blocking: blocking,
            created_at_ms: created_at_ms,
            metadata: metadata.nil? ? intent.metadata : metadata
          )
        end
      end

      def initialize(
        workflow_id:,
        revision:,
        node_id:,
        attempt_id:,
        type:,
        key:,
        payload:,
        payload_fingerprint:,
        blocking:,
        created_at_ms:,
        metadata: {},
        ref: nil
      )
        # `ref:` is accepted only so `Data#with` round-trips correctly. It is
        # always recomputed from `type:key` below; user input passes through
        # `[]`, which does not expose the kwarg.
        DAG::Effects.validate_ref_part!(type, "type")
        DAG::Effects.validate_ref_part!(key, "key")
        validate_string!(workflow_id, "workflow_id")
        validate_revision!(revision)
        validate_node_id!(node_id)
        validate_string!(attempt_id, "attempt_id")
        validate_string!(payload_fingerprint, "payload_fingerprint")
        validate_boolean!(blocking, "blocking")
        validate_integer!(created_at_ms, "created_at_ms")
        DAG.json_safe!(payload, "$root.payload")
        DAG.json_safe!(metadata, "$root.metadata")

        super(
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
          created_at_ms: created_at_ms,
          metadata: DAG.deep_freeze(DAG.deep_dup(metadata))
        )
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

      def validate_integer!(value, label)
        raise ArgumentError, "#{label} must be Integer" unless value.is_a?(Integer)
      end
    end
  end
end
