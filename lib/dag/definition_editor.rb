# frozen_string_literal: true

module DAG
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
      kept_nodes = definition.nodes - removed
      replacement_nodes = replacement.graph.nodes
      conflicts = kept_nodes & replacement_nodes
      raise ArgumentError, "replacement nodes collide with preserved nodes: #{sorted(conflicts).inspect}" unless conflicts.empty?

      new_graph = build_replaced_graph(definition, target, removed, kept_nodes, replacement, replacement_nodes)
      step_types = build_step_types(definition, kept_nodes, replacement_nodes)
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
      validate_node_id_list!(replacement.entry_node_ids, "entry_node_ids", replacement.graph)
      validate_node_id_list!(replacement.exit_node_ids, "exit_node_ids", replacement.graph)
    end

    def validate_node_id_list!(ids, label, graph)
      raise ArgumentError, "#{label} must be an Array" unless ids.is_a?(Array)
      raise ArgumentError, "#{label} cannot be empty" if ids.empty?

      ids.each do |id|
        raise ArgumentError, "#{label} entries must be Symbol or String, got #{id.class}: #{id.inspect}" unless id.is_a?(Symbol) || id.is_a?(String)
        raise ArgumentError, "replacement #{label.sub("_node_ids", "")} node is not in graph: #{id}" unless graph.node?(id)
      end
    end

    def build_replaced_graph(definition, target, removed, kept_nodes, replacement, replacement_nodes)
      entries_sorted = sorted(replacement.entry_node_ids)
      exits_sorted = sorted(replacement.exit_node_ids)

      graph = DAG::Graph.new
      sorted(kept_nodes).each { |node_id| graph.add_node(node_id) }
      sorted(replacement_nodes).each { |node_id| graph.add_node(node_id) }
      copy_preserved_edges(graph, definition.graph, removed)
      copy_replacement_edges(graph, replacement.graph)
      copy_entry_edges(graph, definition, target, entries_sorted)
      copy_exit_edges(graph, definition, removed, exits_sorted)
      graph.freeze
    end

    def copy_preserved_edges(graph, source_graph, removed)
      sorted_edges(source_graph).each do |edge|
        next if removed.include?(edge.from) || removed.include?(edge.to)

        graph.add_edge(edge.from, edge.to, **edge.metadata)
      end
    end

    def copy_replacement_edges(graph, source_graph)
      sorted_edges(source_graph).each do |edge|
        graph.add_edge(edge.from, edge.to, **edge.metadata)
      end
    end

    def copy_entry_edges(graph, definition, target, entries_sorted)
      sorted(definition.each_predecessor(target)).each do |predecessor|
        metadata = definition.graph.edge_metadata(predecessor, target)
        entries_sorted.each { |entry| graph.add_edge(predecessor, entry, **metadata) }
      end
    end

    def copy_exit_edges(graph, definition, removed, exits_sorted)
      external_edges = sorted(removed).flat_map do |node_id|
        sorted(definition.each_successor(node_id)).filter_map do |successor|
          next if removed.include?(successor)

          [successor, definition.graph.edge_metadata(node_id, successor)]
        end
      end

      exits_sorted.each do |exit_node|
        external_edges.each { |successor, metadata| graph.add_edge(exit_node, successor, **metadata) }
      end
    end

    def build_step_types(definition, kept_nodes, replacement_nodes)
      step_types = {}
      sorted(kept_nodes).each { |node_id| step_types[node_id] = definition.step_type_for(node_id) }
      sorted(replacement_nodes).each { |node_id| step_types[node_id] = DEFAULT_REPLACEMENT_STEP }
      step_types
    end

    def sorted(values) = values.sort_by(&:to_s)

    def sorted_edges(graph)
      graph.edges.sort_by { |edge| [edge.from.to_s, edge.to.to_s] }
    end
  end
end
