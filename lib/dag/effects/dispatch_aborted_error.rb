# frozen_string_literal: true

module DAG
  module Effects
    # Raised by `Dispatcher#tick` when dispatching aborts on an unexpected
    # exception (a dispatcher-side storage failure, or an unknown effect
    # type under `unknown_handler_policy: :raise`). Sibling workers may have
    # already durably marked effects and released nodes before the abort;
    # {#report} carries those partial outcomes so the caller does not lose
    # them. The original exception is available via `Exception#cause`.
    # Records that were claimed but never marked stay `:dispatching` until
    # their lease expires and a future tick re-claims them.
    # @api public
    class DispatchAbortedError < DAG::Error
      # @return [DAG::Effects::DispatchReport] outcomes completed before the abort
      attr_reader :report

      # @param message [String]
      # @param report [DAG::Effects::DispatchReport]
      def initialize(message, report:)
        @report = report
        super(message)
      end
    end
  end
end
