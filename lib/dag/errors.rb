# frozen_string_literal: true

module DAG
  # Base class for every exception raised by `ruby-dag`. Consumers can
  # rescue `DAG::Error` to catch any kernel-originated failure.
  # @api public
  class Error < StandardError; end

  # Raised when a port method has no implementation in the supplied adapter.
  # @api public
  class PortNotImplementedError < Error; end

  # Raised by storage CAS when the supplied `expected_revision` no longer
  # matches the workflow's current revision.
  # @api public
  class StaleRevisionError < Error; end

  # Raised when a workflow is in an unexpected state for the requested
  # transition (for example, calling `Runner#call` on a `:running` workflow).
  # @api public
  class StaleStateError < Error; end

  # Raised by `Graph#add_edge` when adding an edge would introduce a cycle.
  # The message names the offending edge.
  # @api public
  class CycleError < Error; end

  # Raised when a node id is added twice to the same graph or definition.
  # @api public
  class DuplicateNodeError < Error; end

  # Raised when a step type is re-registered with a different
  # `fingerprint_payload`. The fingerprint must be deterministic, so an
  # observable change is treated as a programmer error.
  # @api public
  class FingerprintMismatchError < Error; end

  # Raised by `MutationService#apply` when the workflow is `:running`.
  # Mutations require `:paused` or `:waiting`.
  # @api public
  class ConcurrentMutationError < Error; end

  # Raised when a node id is referenced but not present in the graph or
  # definition.
  # @api public
  class UnknownNodeError < Error; end

  # Raised when a definition references a step type that was not registered
  # on the runner's `StepTypeRegistry`.
  # @api public
  class UnknownStepTypeError < Error; end

  # Raised when a workflow id is requested from storage but does not exist.
  # @api public
  class UnknownWorkflowError < Error; end

  # Raised by `Runner#retry_workflow` when the workflow has already been
  # retried `runtime_profile.max_workflow_retries` times.
  # @api public
  class WorkflowRetryExhaustedError < Error; end

  # Raised by serializers when a value cannot be serialized.
  # @api public
  class SerializationError < Error; end

  # Raised when a structural validator finds one or more violations.
  # `#errors` returns the underlying violation messages.
  # @api public
  class ValidationError < Error
    # @return [Array<String>] underlying violation messages
    attr_reader :errors

    # @param errors [Array<String>, String] one or more violation messages
    def initialize(errors)
      @errors = Array(errors)
      super(@errors.join("; "))
    end
  end
end
