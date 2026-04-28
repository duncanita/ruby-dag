# frozen_string_literal: true

module DAG
  # Step namespace: base class for user-implemented step types.
  # @api public
  module Step
    # Base class for built-in and user step types. Subclasses override `#call`.
    # Config is deep-frozen and the instance is frozen at construction.
    # @api public
    class Base
      # @return [Hash] deep-frozen step configuration
      attr_reader :config

      def initialize(config: {})
        @config = DAG.frozen_copy(config)
        freeze
      end

      def call(input)
        raise NotImplementedError, "#{self.class} must implement #call(input)"
      end
    end
  end
end
