# frozen_string_literal: true

module DAG
  class CycleError < StandardError; end

  class ValidationError < StandardError
    attr_reader :errors

    def initialize(errors)
      @errors = errors
      super(errors.join("; "))
    end
  end
end
