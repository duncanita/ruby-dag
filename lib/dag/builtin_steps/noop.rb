# frozen_string_literal: true

module DAG
  module BuiltinSteps
    # Always succeeds with `nil` and an empty context patch. Useful as a
    # placeholder node, sync barrier, or test fixture.
    class Noop < DAG::Step::Base
      def call(_input)
        DAG::Success[value: nil, context_patch: {}]
      end
    end
  end
end
