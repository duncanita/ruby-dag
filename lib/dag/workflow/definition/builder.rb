# frozen_string_literal: true

module DAG
  module Workflow
    class Definition
      # Bulk builder for generated or large workflow definitions. Mutation is
      # local to the builder; `build` returns a frozen `Definition`.
      # @api public
      class Builder
        # Yield a fresh Builder, then return its built Definition.
        # @return [DAG::Workflow::Definition]
        def self.build(revision: 1)
          builder = new(revision: revision)
          yield builder
          builder.build
        end

        def initialize(revision: 1)
          DAG::Validation.revision!(revision)

          @graph = DAG::Graph.new
          @step_types = {}
          @revision = revision
        end

        # @return [self]
        def add_node(id, type:, config: {})
          sym = id.to_sym
          DAG::Validation.symbol!(type, "type")

          @graph.add_node(sym)
          @step_types[sym] = {type: type, config: DAG.frozen_copy(config)}
          self
        end

        # @return [self]
        def add_edge(from, to, **metadata)
          @graph.add_edge(from, to, **metadata)
          self
        end

        # @return [DAG::Workflow::Definition]
        def build
          DAG::Workflow::Definition.new(
            graph: @graph.freeze,
            step_types: @step_types,
            revision: @revision
          )
        end
      end
    end
  end
end
