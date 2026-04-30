# frozen_string_literal: true

module DAG
  module Effects
    # Raised when an effect lease is missing, expired, or owned by another
    # dispatcher.
    # @api public
    class StaleLeaseError < DAG::Error; end
  end
end
