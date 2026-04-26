# frozen_string_literal: true

module DAG
  module Step
    # Base class for built-in and user step types. Subclasses override `#call`.
    # Config is deep-frozen and the instance is frozen at construction.
    class Base
      attr_reader :config

      def initialize(config: {})
        @config = DAG.deep_freeze(DAG.deep_dup(config))
        freeze
      end

      def call(input)
        raise NotImplementedError, "#{self.class} must implement #call(input)"
      end
    end
  end
end
