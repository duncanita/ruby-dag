# frozen_string_literal: true

module DAG
  module Effects
    # Explicit opt-in wrapper for handlers that accept a lease signal as
    # their second argument. Legacy handlers keep the one-argument call.
    # @api public
    class CooperativeHandler
      # @param handler [#call] callable accepting (record, lease_signal)
      def initialize(handler)
        DAG::Validation.dependency!(handler, :call, "handler")
        @handler = handler
        freeze
      end

      # @param record [DAG::Effects::Record]
      # @param signal [DAG::Effects::LeaseSignal]
      # @return [DAG::Effects::HandlerResult]
      def call(record, signal)
        @handler.call(record, signal)
      end
    end
  end
end
