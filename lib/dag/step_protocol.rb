# frozen_string_literal: true

module DAG
  # Step protocol contract:
  #
  #   #call(StepInput) -> Success | Waiting | Failure
  #
  # Steps must be idempotent functions of their `StepInput`. The kernel
  # guarantees at-most-once result commit, not at-most-once invocation.
  #
  # If a step raises `StandardError`, the Runner converts it to a
  # `Failure[error: {class:, message:}, retriable: false]`. `NoMemoryError`,
  # `SystemExit`, and `Interrupt` are intentionally NOT caught; they
  # propagate up.
  module StepProtocol
    VALID_RESULT_CLASSES = [DAG::Success, DAG::Waiting, DAG::Failure].freeze

    module_function

    # Returns true iff `klass` exposes a `#call` instance method that takes a
    # single positional or keyword argument (the StepInput).
    def implements?(klass)
      return false unless klass.is_a?(Class)
      return false unless klass.public_method_defined?(:call)
      arity = klass.instance_method(:call).arity
      [1, -1, -2].include?(arity)
    end

    def valid_result?(value)
      VALID_RESULT_CLASSES.any? { |klass| value.is_a?(klass) }
    end
  end
end
