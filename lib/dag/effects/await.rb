# frozen_string_literal: true

module DAG
  module Effects
    # Monad-like step helper for awaiting an abstract effect. It maps effect
    # snapshots into legal step results and yields the succeeded result into a
    # pure continuation.
    # @api public
    module Await
      class << self
        # @param input [DAG::StepInput, #metadata]
        # @param intent [DAG::Effects::Intent]
        # @param not_before_ms [Integer, nil]
        # @yieldparam result [Object] JSON-safe effect result
        # @return [DAG::Success, DAG::Waiting, DAG::Failure]
        def call(input, intent, not_before_ms: nil)
          raise ArgumentError, "intent must be DAG::Effects::Intent" unless intent.is_a?(DAG::Effects::Intent)
          DAG::Validation.optional_integer!(not_before_ms, "not_before_ms")

          record = effect_snapshot(input, intent)
          case DAG::Effects.fetch_snapshot_value(record, :status)&.to_sym
          when :succeeded
            result = yield(DAG::Effects.fetch_required_snapshot_value(record, :result))
            return result if DAG::StepProtocol.valid_result?(result)

            raise TypeError, "Await continuation must return Success, Waiting, or Failure, got #{result.class}"
          when :failed_terminal
            DAG::Failure[
              error: DAG::Effects.fetch_required_snapshot_value(record, :error),
              retriable: false,
              metadata: {effect_ref: intent.ref}
            ]
          when :failed_retriable
            pending(intent, not_before_ms: DAG::Effects.fetch_snapshot_value(record, :not_before_ms) || not_before_ms)
          else
            pending(intent, not_before_ms: not_before_ms)
          end
        end

        private

        def effect_snapshot(input, intent)
          metadata = input.respond_to?(:metadata) ? input.metadata : {}
          effects = DAG::Effects.fetch_snapshot_value(metadata, :effects, {})
          DAG::Effects.fetch_snapshot_value(effects, intent.ref)
        end

        def pending(intent, not_before_ms:)
          DAG::Waiting[
            reason: :effect_pending,
            resume_token: {effects: [intent.ref]},
            not_before_ms: not_before_ms,
            proposed_effects: [intent],
            metadata: {effect_ref: intent.ref}
          ]
        end
      end
    end
  end
end
