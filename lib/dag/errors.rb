# frozen_string_literal: true

module DAG
  class Error < StandardError; end

  class CycleError < Error; end
  class DuplicateNodeError < Error; end
  class UnknownNodeError < Error; end
  class SerializationError < Error; end
  class ParallelSafetyError < Error; end

  class ValidationError < Error
    attr_reader :errors

    def initialize(errors)
      @errors = Array(errors)
      super(@errors.join("; "))
    end
  end
end
