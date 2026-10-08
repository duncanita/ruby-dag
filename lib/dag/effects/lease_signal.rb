# frozen_string_literal: true

module DAG
  module Effects
    # Frozen per-dispatch interface for cooperative lease renewal and loss
    # observation. The dispatcher owns the loss flag and storage callbacks.
    # @api public
    class LeaseSignal
      # @param renew [#call] callback taking until_ms
      # @param lost [#call] callback returning Boolean
      def initialize(renew:, lost:)
        DAG::Validation.dependency!(renew, :call, "renew")
        DAG::Validation.dependency!(lost, :call, "lost")
        @renew = renew
        @lost = lost
        freeze
      end

      # Renew through the storage lease CAS. A lost lease raises
      # {DAG::Effects::StaleLeaseError} and permanently signals loss.
      # @param until_ms [Integer] new lease deadline
      # @return [DAG::Effects::Record] renewed record
      def renew!(until_ms:)
        @renew.call(until_ms)
      end

      # @return [Boolean] whether a renewal detected lease loss
      def lost?
        @lost.call
      end
    end
  end
end
