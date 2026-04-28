# frozen_string_literal: true

module DAG
  # Built-in step types shipped with `ruby-dag`. Registered explicitly by
  # consumers on a `DAG::StepTypeRegistry` (the kernel does not auto-register).
  # @api public
  module BuiltinSteps
    # Always succeeds with `nil` and an empty context patch. Useful as a
    # placeholder node, sync barrier, or test fixture.
    # @api public
    class Noop < DAG::Step::Base
      # @return [DAG::Success]
      def call(_input)
        DAG::Success[value: nil, context_patch: {}]
      end
    end
  end
end
