# frozen_string_literal: true

module DAG
  Success = Data.define(:value) do
    include Result

    def success? = true
    def failure? = false
    def error = nil

    def and_then
      Result.assert_result!(yield(value), "and_then")
    end

    def map
      Success.new(value: yield(value))
    end

    def map_error = self

    def tap
      yield(value)
      self
    end

    def tap_error = self

    def recover = self

    def unwrap! = value
    def value_or(_default) = value
    def to_h = {status: :success, value: value}
    def inspect = "Success(#{value.inspect})"
    alias_method :to_s, :inspect
  end
end
