# frozen_string_literal: true

module DAG
  PlanResult = Data.define(:valid, :new_definition, :invalidated_node_ids, :reason) do
    class << self
      def valid(new_definition:, invalidated_node_ids:)
        new(valid: true, new_definition: new_definition, invalidated_node_ids: invalidated_node_ids, reason: nil)
      end

      def invalid(reason)
        new(valid: false, new_definition: nil, invalidated_node_ids: [], reason: reason)
      end
    end

    def initialize(valid:, new_definition:, invalidated_node_ids:, reason:)
      super(
        valid: valid,
        new_definition: new_definition,
        invalidated_node_ids: DAG.deep_freeze(invalidated_node_ids.map(&:to_sym).sort_by(&:to_s)),
        reason: reason
      )
    end

    def valid? = valid
  end

  class DefinitionEditor
    DEFAULT_REPLACEMENT_STEP = {type: :noop, config: {}}.freeze

    def plan(definition, mutation)
      raise ArgumentError, "definition must be a DAG::Workflow::Definition" unless definition.is_a?(DAG::Workflow::Definition)
      raise ArgumentError, "mutation must be a DAG::ProposedMutation" unless mutation.is_a?(DAG::ProposedMutation)

      case mutation.kind
      when :invalidate then plan_invalidate(definition, mutation)
      when :replace_subtree then plan_replace_subtree(definition, mutation)
      else
        DAG::PlanResult.invalid("unsupported mutation kind: #{mutation.kind.inspect}")
      end
    rescue DAG::CycleError, DAG::DuplicateNodeError, DAG::UnknownNodeError, ArgumentError => e
      DAG::PlanResult.invalid(e.message)
    end

    private

    def plan_invalidate(definition, mutation)
      target = mutation.target_node_id.to_sym
      return DAG::PlanResult.invalid("unknown target node: #{target}") unless definition.has_node?(target)

      DAG::PlanResult.valid(
        new_definition: definition,
        invalidated_node_ids: definition.descendants_of(target, include_self: true)
      )
    end

    def plan_replace_subtree(definition, mutation)
      target = mutation.target_node_id.to_sym
      return DAG::PlanResult.invalid("unknown target node: #{target}") unless definition.has_node?(target)

      replacement = mutation.replacement_graph
      validate_replacement_graph!(replacement)

      removed = definition.exclusive_descendants_of(target, include_self: true)
      impacted = definition.descendants_of(target, include_self: true) - removed
      new_graph = replaced_graph(definition, target, removed, replacement)
      step_types = replaced_step_types(definition, removed, replacement)
      new_definition = DAG::Workflow::Definition.new(
        graph: new_graph,
        step_types: step_types,
        revision: definition.revision
      )

      DAG::PlanResult.valid(new_definition: new_definition, invalidated_node_ids: impacted)
    end

    def validate_replacement_graph!(replacement)
      raise ArgumentError, "replacement_graph must be a DAG::ReplacementGraph" unless replacement.is_a?(DAG::ReplacementGraph)
      raise ArgumentError, "replacement graph must be a DAG::Graph" unless replacement.graph.is_a?(DAG::Graph)

      replacement.entry_node_ids.each do |node_id|
        raise ArgumentError, "replacement entry node is not in graph: #{node_id}" unless replacement.graph.node?(node_id)
      end
      replacement.exit_node_ids.each do |node_id|
        raise ArgumentError, "replacement exit node is not in graph: #{node_id}" unless replacement.graph.node?(node_id)
      end
    end

    def replaced_graph(definition, target, removed, replacement)
      graph = DAG::Graph.new
      kept_nodes = definition.nodes - removed
      replacement_nodes = replacement.graph.nodes
      conflicts = kept_nodes & replacement_nodes
      raise ArgumentError, "replacement nodes collide with preserved nodes: #{sorted(conflicts).inspect}" unless conflicts.empty?

      sorted(kept_nodes).each { |node_id| graph.add_node(node_id) }
      sorted(replacement_nodes).each { |node_id| graph.add_node(node_id) }
      add_preserved_edges(graph, definition, removed)
      add_replacement_edges(graph, replacement.graph)
      add_entry_edges(graph, definition, target, replacement)
      add_exit_edges(graph, definition, removed, replacement)
      graph.freeze
    end

    def add_preserved_edges(graph, definition, removed)
      sorted_edges(definition.graph).each do |edge|
        next if removed.include?(edge.from) || removed.include?(edge.to)

        graph.add_edge(edge.from, edge.to, **edge.metadata)
      end
    end

    def add_replacement_edges(graph, replacement_graph)
      sorted_edges(replacement_graph).each do |edge|
        graph.add_edge(edge.from, edge.to, **edge.metadata)
      end
    end

    def add_entry_edges(graph, definition, target, replacement)
      sorted(definition.predecessors(target)).each do |predecessor|
        metadata = definition.graph.edge_metadata(predecessor, target)
        sorted(replacement.entry_node_ids).each do |entry|
          graph.add_edge(predecessor, entry, **metadata)
        end
      end
    end

    def add_exit_edges(graph, definition, removed, replacement)
      external_edges = sorted(removed).flat_map do |node_id|
        sorted(definition.successors(node_id)).filter_map do |successor|
          next if removed.include?(successor)

          [successor, definition.graph.edge_metadata(node_id, successor)]
        end
      end

      sorted(replacement.exit_node_ids).each do |exit_node|
        external_edges.each do |successor, metadata|
          graph.add_edge(exit_node, successor, **metadata)
        end
      end
    end

    def replaced_step_types(definition, removed, replacement)
      step_types = {}
      sorted(definition.nodes - removed).each do |node_id|
        step_types[node_id] = definition.step_type_for(node_id)
      end
      sorted(replacement.graph.nodes).each do |node_id|
        step_types[node_id] = DEFAULT_REPLACEMENT_STEP
      end
      step_types
    end

    def sorted(values) = values.to_a.sort_by(&:to_s)

    def sorted_edges(graph)
      graph.edges.to_a.sort_by { |edge| [edge.from.to_s, edge.to.to_s] }
    end
  end
end
