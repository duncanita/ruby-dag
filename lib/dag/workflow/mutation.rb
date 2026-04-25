# frozen_string_literal: true

module DAG
  module Workflow
    class << self
      def subtree_replacement_impact(workflow_id:, definition:, root_node:, execution_store:)
        raise ArgumentError, "definition must be a DAG::Workflow::Definition" unless definition.is_a?(Definition)

        run = execution_store.load_run(workflow_id)
        return {obsolete_nodes: [], stale_nodes: []} unless run

        root = mutation_node_path(root_node)
        raise_if_running_mutation_root!(run, root)

        obsolete_nodes = node_completed?(run, root) ? [root] : []
        stale_nodes = definition.graph.descendants(root.last).sort.each_with_object([]) do |name, nodes|
          node_path = mutation_node_path(name)
          nodes << node_path if node_completed?(run, node_path)
        end

        {
          obsolete_nodes: obsolete_nodes.sort_by { |node_path| node_path.map(&:to_s) },
          stale_nodes: stale_nodes.sort_by { |node_path| node_path.map(&:to_s) }
        }
      end

      def apply_subtree_replacement_impact(workflow_id:, definition:, root_node:, execution_store:,
        cause: nil, new_definition: nil, root_input: {})
        impact = subtree_replacement_impact(
          workflow_id: workflow_id,
          definition: definition,
          root_node: root_node,
          execution_store: execution_store
        )
        root = mutation_node_path(root_node)
        normalized_cause = subtree_replacement_cause(root, cause)

        unless impact[:obsolete_nodes].empty?
          execution_store.mark_obsolete(
            workflow_id: workflow_id,
            node_paths: impact[:obsolete_nodes],
            cause: normalized_cause
          )
        end

        unless impact[:stale_nodes].empty?
          execution_store.mark_stale(
            workflow_id: workflow_id,
            node_paths: impact[:stale_nodes],
            cause: normalized_cause
          )
        end

        update_mutated_definition!(execution_store, workflow_id, new_definition, root_input: root_input)

        impact
      end

      def replace_subtree(definition, root_node:, replacement:, reconnect: [])
        raise ArgumentError, "definition must be a DAG::Workflow::Definition" unless definition.is_a?(Definition)
        raise ArgumentError, "replacement must be a DAG::Workflow::Definition" unless replacement.is_a?(Definition)

        root = root_node.to_sym
        removed = [root]
        normalized_reconnect = normalize_reconnect_alias_entries(definition.graph, root, reconnect)
        validate_reconnect_aliases!(definition.graph, root, normalized_reconnect)

        new_graph = definition.graph.with_subtree_replaced(
          root: root,
          replacement_graph: replacement.graph,
          reconnect: reconnect
        )
        new_registry = definition.registry.dup
        removed.each { |name| new_registry.remove(name) }
        replacement.registry.steps.each { |step| new_registry.register(step) }
        rewrite_reconnected_run_if_refs!(new_registry, definition.graph, root, normalized_reconnect)

        Definition.new(graph: new_graph, registry: new_registry, source_path: definition.source_path)
      end

      private

      def normalize_reconnect_alias_entries(graph, root, reconnect)
        Array(reconnect).map do |descriptor|
          normalize_reconnect_alias_entry(descriptor, graph: graph, root: root)
        end
      end

      def validate_reconnect_aliases!(graph, root, normalized_reconnect)
        aliases_by_target = Hash.new { |hash, key| hash[key] = Set.new }
        normalized_reconnect.each do |entry|
          target = entry.fetch(:to)
          aliases = aliases_by_target[target]

          graph.each_predecessor(target) do |predecessor|
            next if predecessor == root

            aliases << effective_input_key(predecessor, graph.edge_metadata(predecessor, target))
          end
        end

        normalized_reconnect.each do |entry|
          target = entry.fetch(:to)
          merged = graph.merged_edge_metadata(root, target, entry[:metadata])
          alias_key = effective_input_key(entry.fetch(:from), merged)

          if aliases_by_target[target].include?(alias_key)
            raise ArgumentError, "duplicate effective downstream alias for #{target}: #{alias_key}"
          end

          aliases_by_target[target] << alias_key
        end
      end

      def rewrite_reconnected_run_if_refs!(registry, graph, root, normalized_reconnect)
        reconnects_by_target = normalized_reconnect.group_by { |entry| entry.fetch(:to) }

        graph.each_successor(root) do |target|
          next unless registry.key?(target)

          step = registry[target]
          run_if = step.config[:run_if]
          referenced = Condition.referenced_from_keys(run_if)
          next if referenced.empty?

          old_input_key = effective_input_key(root, graph.edge_metadata(root, target))
          next unless referenced.include?(old_input_key)

          reconnects = reconnects_by_target.fetch(target, [])
          raise_stale_run_if_reconnect_error!(target, root) if reconnects.empty?
          raise_ambiguous_run_if_reconnect_error!(target, root, reconnects) if reconnects.size > 1

          new_input_key = effective_input_key(reconnects.first.fetch(:from), reconnects.first.fetch(:metadata))
          if external_dependency_input_keys(step).include?(new_input_key)
            raise_external_run_if_alias_collision_error!(target, root, new_input_key)
          end

          rewritten = Condition.rename_from(run_if, old_input_key, new_input_key)
          registry.replace(Step.new(name: step.name, type: step.type, **step.config.merge(run_if: rewritten)))
        end
      end

      def raise_stale_run_if_reconnect_error!(target, root)
        raise ArgumentError,
          "subtree replacement would leave node #{target} run_if referencing removed node #{root}; " \
          "reconnect #{root} to #{target} or update run_if before replacing the subtree"
      end

      def raise_ambiguous_run_if_reconnect_error!(target, root, reconnects)
        leaves = reconnects.map { |entry| entry.fetch(:from) }.sort
        raise ArgumentError,
          "ambiguous run_if rewrite for node #{target}: removed node #{root} reconnects through " \
          "multiple replacement leaves #{leaves.inspect}"
      end

      def raise_external_run_if_alias_collision_error!(target, root, replacement_leaf)
        raise ArgumentError,
          "ambiguous run_if rewrite for node #{target}: removed node #{root} reconnects through " \
          "replacement leaf #{replacement_leaf}, which collides with an external dependency alias on #{target}"
      end

      def external_dependency_input_keys(step)
        Array(step.config[:external_dependencies]).filter_map do |dependency|
          normalized = dependency.transform_keys(&:to_sym)
          key = normalized[:as] || normalized[:node]
          key&.to_sym
        end
      end

      def normalize_reconnect_alias_entry(descriptor, graph:, root:)
        raise ArgumentError, "reconnect entries must be Hashes" unless descriptor.is_a?(Hash)

        entry = descriptor.transform_keys(&:to_sym)
        raise ArgumentError, "reconnect entries must include :from" unless entry.key?(:from)
        raise ArgumentError, "reconnect entries must include :to" unless entry.key?(:to)

        {
          from: entry.fetch(:from).to_sym,
          to: entry.fetch(:to).to_sym,
          metadata: graph.merged_edge_metadata(root, entry.fetch(:to), entry[:metadata])
        }
      end

      def effective_input_key(from, metadata)
        (metadata[:as] || from).to_sym
      end

      def subtree_replacement_cause(root, custom_cause)
        {code: :subtree_replaced}.merge(normalize_subtree_replacement_cause(custom_cause)).merge(replaced_from: root)
      end

      def normalize_subtree_replacement_cause(cause)
        return {} if cause.nil?
        raise ArgumentError, "cause must be a Hash" unless cause.is_a?(Hash)

        normalized = cause.transform_keys(&:to_sym)
        raise ArgumentError, "cause cannot override replaced_from" if normalized.key?(:replaced_from)

        normalized
      end

      def node_completed?(run, node_path)
        run.dig(:nodes, node_path, :state) == :completed
      end

      def raise_if_running_mutation_root!(run, root)
        return unless run.dig(:nodes, root, :state) == :running

        raise ArgumentError, "replaced subtree root cannot currently be :running"
      end

      def update_mutated_definition!(execution_store, workflow_id, new_definition, root_input:)
        return if new_definition.nil?
        raise ArgumentError, "new_definition must be a DAG::Workflow::Definition" unless new_definition.is_a?(Definition)
        return unless execution_store.respond_to?(:update_definition)

        execution_store.update_definition(
          workflow_id: workflow_id,
          definition_fingerprint: DefinitionFingerprint.for(new_definition, root_input: root_input),
          node_paths: new_definition.graph.topological_sort.map { |name| mutation_node_path(name) }
        )
      end

      def mutation_node_path(node_path)
        Array(node_path).map(&:to_sym).freeze
      end
    end
  end
end
