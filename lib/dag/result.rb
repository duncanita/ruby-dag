# frozen_string_literal: true

module DAG
  # Minimal Result monad — Success or Failure.
  # No dependencies, no magic. Just a value wrapper with railway semantics.
  #
  #   result = Success(42)
  #   result.success?  #=> true
  #   result.value     #=> 42
  #
  #   result = Failure("boom")
  #   result.failure?  #=> true
  #   result.error     #=> "boom"
  #
  #   # Railway: chain operations, stop at first failure
  #   result.and_then { |v| Success(v * 2) }
  #          .and_then { |v| Failure("too big") if v > 100 }

  class Result
    attr_reader :value, :error

    def initialize(value: nil, error: nil, success:)
      @value = value
      @error = error
      @success = success
      freeze
    end

    def success? = @success
    def failure? = !@success

    # Chain on success, short-circuit on failure.
    # Block receives the value, must return a Result.
    def and_then
      return self if failure?

      yield(@value)
    end

    # Transform the value inside a Success, pass through Failure.
    def map
      return self if failure?

      Result.success(yield(@value))
    end

    # Transform the error inside a Failure, pass through Success.
    def map_error
      return self if success?

      Result.failure(yield(@error))
    end

    # Unwrap value or raise
    def unwrap!
      raise "Unwrap called on Failure: #{@error}" if failure?

      @value
    end

    # Unwrap value or return default
    def value_or(default)
      success? ? @value : default
    end

    def to_h
      if success?
        { status: :success, value: @value }
      else
        { status: :failure, error: @error }
      end
    end

    def inspect
      if success?
        "Success(#{@value.inspect})"
      else
        "Failure(#{@error.inspect})"
      end
    end
    alias_method :to_s, :inspect

    # Factory methods
    def self.success(value = nil) = new(value: value, success: true)
    def self.failure(error = nil) = new(error: error, success: false)
  end

  # Top-level convenience constructors
  def self.Success(value = nil) = Result.success(value)
  def self.Failure(error = nil) = Result.failure(error)
end
