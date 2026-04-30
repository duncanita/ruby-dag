# frozen_string_literal: true

module DAG
  module Effects
    # Raised when the same effect ref is reserved with a different payload
    # fingerprint.
    # @api public
    class IdempotencyConflictError < DAG::Error; end
  end
end
