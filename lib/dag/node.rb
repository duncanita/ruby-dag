# frozen_string_literal: true

module DAG
  # Immutable node in the DAG. Wraps a step type with metadata.
  Node = Data.define(:name, :type, :depends_on, :config) do
    def initialize(name:, type:, depends_on: [], **config)
      super(
        name: name.to_sym,
        type: type.to_sym,
        depends_on: Array(depends_on).map(&:to_sym).freeze,
        config: config.freeze
      )
    end

    def to_s = "Node(#{name}:#{type})"
    def inspect = to_s
  end
end
