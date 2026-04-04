# frozen_string_literal: true

module DAG
  # Minimal Result monad — Success or Failure.
  # Immutable via Data.define. Railway semantics via .then chains.
  #
  #   Success(42)
  #     .and_then { |v| Success(v * 2) }
  #     .and_then { |v| v > 100 ? Failure("too big") : Success(v) }
  #
  #   # Or with .then for complex pipelines:
  #   validate(input)
  #     .then { |r| r.and_then { |v| transform(v) } }
  #     .then { |r| r.and_then { |v| persist(v) } }

  Success = Data.define(:value) do
    def success? = true
    def failure? = false
    def error = nil

    def and_then = yield(value)
    def map = Success.new(value: yield(value))
    def map_error = self
    def unwrap! = value
    def value_or(_default) = value
    def to_h = { status: :success, value: value }
    def inspect = "Success(#{value.inspect})"
    alias_method :to_s, :inspect
  end

  Failure = Data.define(:error) do
    def success? = false
    def failure? = true
    def value = nil

    def and_then = self
    def map = self
    def map_error = Failure.new(error: yield(error))
    def unwrap! = raise("Unwrap called on Failure: #{error}")
    def value_or(default) = default
    def to_h = { status: :failure, error: error }
    def inspect = "Failure(#{error.inspect})"
    alias_method :to_s, :inspect
  end

  def self.Success(value = nil) = Success.new(value: value)
  def self.Failure(error = nil) = Failure.new(error: error)
end
