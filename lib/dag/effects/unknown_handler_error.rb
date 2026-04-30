# frozen_string_literal: true

module DAG
  module Effects
    # Raised when no handler is registered for an effect type.
    # @api public
    class UnknownHandlerError < DAG::Error; end
  end
end
