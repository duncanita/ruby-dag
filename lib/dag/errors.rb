# frozen_string_literal: true

module DAG
  class Error < StandardError; end

  class PortNotImplementedError < Error; end
  class StaleRevisionError < Error; end
  class StaleStateError < Error; end
  class CycleError < Error; end
  class DuplicateNodeError < Error; end
  class FingerprintMismatchError < Error; end
  class ConcurrentMutationError < Error; end
  class UnknownNodeError < Error; end
  class UnknownStepTypeError < Error; end
  class UnknownWorkflowError < Error; end
  class WorkflowRetryExhaustedError < Error; end
  class SerializationError < Error; end

  class ValidationError < Error
    attr_reader :errors

    def initialize(errors)
      @errors = Array(errors)
      super(@errors.join("; "))
    end
  end
end
