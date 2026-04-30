# frozen_string_literal: true

module DAG
  module Effects
    # Raised when an effect ref or id cannot be found in durable storage.
    # @api public
    class UnknownEffectError < DAG::Error; end
  end
end
