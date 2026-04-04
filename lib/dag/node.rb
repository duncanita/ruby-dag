# frozen_string_literal: true

module DAG
  # A node in the DAG. Wraps a callable step with metadata.
  #
  # Each node:
  # - Has a unique name
  # - Has a type (:exec, :script, :llm, :file_read, :file_write, :ruby)
  # - Declares dependencies (names of nodes that must complete first)
  # - Receives merged outputs from dependencies as input
  # - Returns a Result (Success or Failure)

  class Node
    attr_reader :name, :type, :depends_on, :config

    def initialize(name:, type:, depends_on: [], **config)
      @name = name.to_sym
      @type = type.to_sym
      @depends_on = Array(depends_on).map(&:to_sym)
      @config = config
      freeze
    end

    def to_s = "Node(#{@name}:#{@type})"
    def inspect = to_s
  end
end
