# frozen_string_literal: true

module DAG
  # Step protocol:
  #
  #   #call(StepInput) -> Success | Waiting | Failure
  #
  # Steps are idempotent functions of their `StepInput`. The kernel
  # guarantees at-most-once commit of the result, not at-most-once
  # invocation. `StandardError` raised inside `#call` is converted by the
  # Runner to a `Failure[code: :step_raised, ..., retriable: false]`.
  # `NoMemoryError`, `SystemExit`, and `Interrupt` propagate.
  # @api public
  module StepProtocol
    # The three classes a step's `#call` may legally return.
    VALID_RESULT_CLASSES = [DAG::Success, DAG::Waiting, DAG::Failure].freeze

    module_function

    # @param value [Object]
    # @return [Boolean] true iff `value` is one of {VALID_RESULT_CLASSES}
    def valid_result?(value)
      VALID_RESULT_CLASSES.any? { |klass| value.is_a?(klass) }
    end
  end
end
