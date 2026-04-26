# frozen_string_literal: true

module DAG
  module BuiltinSteps
    # Forwards the incoming execution context unchanged: the value carries
    # the context hash, and the context patch is the context itself so that
    # downstream nodes inherit every key.
    class Passthrough < DAG::Step::Base
      def call(input)
        snapshot = input.context.to_h
        DAG::Success[value: snapshot, context_patch: snapshot]
      end
    end
  end
end
