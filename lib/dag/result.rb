# frozen_string_literal: true

module DAG
  # Base module for Result types. Provides the shared interface contract.
  module Result
    def success? = raise NotImplementedError
    def failure? = raise NotImplementedError
  end

  def self.Success(value = nil) = Success.new(value: value)
  def self.Failure(error = nil) = Failure.new(error: error)
end
