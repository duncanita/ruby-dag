# frozen_string_literal: true

require_relative "test_helper"

class GraphTest < Minitest::Test
  # --- Building graphs ---

  def test_add_nodes
    graph = DAG::Graph.new.add_node(:a).add_node(:b)
    assert_equal 2, graph.size
    assert graph.node?(:a)
    assert graph.node?(:b)
  end

  def test_add_edge
    graph = build_graph([:a, :b], [[:a, :b]])
    assert graph.edge?(:a, :b)
    refute graph.edge?(:b, :a)
  end

  def test_rejects_duplicate_node
    assert_raises(DAG::DuplicateNodeError) do
      DAG::Graph.new.add_node(:a).add_node(:a)
    end
  end

  def test_rejects_edge_to_unknown_node
    assert_raises(DAG::UnknownNodeError) do
      DAG::Graph.new.add_node(:a).add_edge(:a, :missing)
    end
  end

  def test_rejects_edge_from_unknown_node
    assert_raises(DAG::UnknownNodeError) do
      DAG::Graph.new.add_node(:a).add_edge(:missing, :a)
    end
  end

  def test_rejects_self_referencing_edge
    assert_raises(ArgumentError) do
      DAG::Graph.new.add_node(:a).add_edge(:a, :a)
    end
  end

  def test_duplicate_edge_is_idempotent
    graph = build_graph([:a, :b], [[:a, :b]])
    graph.add_edge(:a, :b)
    assert_equal 1, graph.edges.size
  end

  # --- Cycle detection on add_edge ---

  def test_detects_two_node_cycle
    assert_raises(DAG::CycleError) do
      graph = DAG::Graph.new.add_node(:a).add_node(:b)
      graph.add_edge(:a, :b)
      graph.add_edge(:b, :a)
    end
  end

  def test_detects_three_node_cycle
    assert_raises(DAG::CycleError) do
      graph = DAG::Graph.new.add_node(:a).add_node(:b).add_node(:c)
      graph.add_edge(:a, :b)
      graph.add_edge(:b, :c)
      graph.add_edge(:c, :a)
    end
  end

  def test_allows_diamond_shape
    graph = DAG::Graph.new.add_node(:a).add_node(:b).add_node(:c).add_node(:d)
    graph.add_edge(:a, :b)
    graph.add_edge(:a, :c)
    graph.add_edge(:b, :d)
    graph.add_edge(:c, :d)
    assert_equal 4, graph.edges.size
  end

  # --- Topological layers ---

  def test_linear_chain
    graph = build_graph([:a, :b, :c], [[:a, :b], [:b, :c]])
    assert_equal [[:a], [:b], [:c]], graph.topological_layers
  end

  def test_independent_nodes_in_same_layer
    graph = build_graph([:a, :b, :c], [[:a, :c], [:b, :c]])
    order = graph.topological_layers
    assert_equal [:a, :b], order[0]
    assert_equal [:c], order[1]
  end

  def test_diamond_dependency
    graph = build_graph([:a, :b, :c, :d], [[:a, :b], [:a, :c], [:b, :d], [:c, :d]])
    order = graph.topological_layers
    assert_equal [:a], order[0]
    assert_equal [:b, :c], order[1]
    assert_equal [:d], order[2]
  end

  def test_single_node
    graph = build_graph([:only], [])
    assert_equal [[:only]], graph.topological_layers
  end

  def test_large_fan_out
    nodes = [:root] + (1..5).map { |i| :"leaf_#{i}" }
    edges = (1..5).map { |i| [:root, :"leaf_#{i}"] }
    graph = build_graph(nodes, edges)

    order = graph.topological_layers
    assert_equal [:root], order[0]
    assert_equal (1..5).map { |i| :"leaf_#{i}" }.sort, order[1]
  end

  def test_empty_graph_sort
    assert_equal [], DAG::Graph.new.topological_layers
  end

  # --- Graph queries ---

  def test_roots
    graph = build_graph([:a, :b, :c], [[:a, :c], [:b, :c]])
    assert_equal [:a, :b].to_set, graph.roots.to_set
  end

  def test_leaves
    graph = build_graph([:a, :b, :c], [[:a, :b], [:a, :c]])
    assert_equal [:b, :c].to_set, graph.leaves.to_set
  end

  def test_successors
    graph = build_graph([:a, :b, :c], [[:a, :b], [:a, :c]])
    assert_equal [:b, :c].to_set, graph.successors(:a)
  end

  def test_predecessors
    graph = build_graph([:a, :b, :c], [[:a, :c], [:b, :c]])
    assert_equal [:a, :b].to_set, graph.predecessors(:c)
  end

  def test_ancestors
    graph = build_graph([:a, :b, :c, :d], [[:a, :b], [:b, :c], [:b, :d]])
    assert_equal [:a, :b].to_set, graph.ancestors(:c)
  end

  def test_descendants
    graph = build_graph([:a, :b, :c, :d], [[:a, :b], [:b, :c], [:b, :d]])
    assert_equal [:b, :c, :d].to_set, graph.descendants(:a)
  end

  def test_ancestors_of_root_is_empty
    graph = build_graph([:a, :b], [[:a, :b]])
    assert_empty graph.ancestors(:a)
  end

  def test_descendants_of_leaf_is_empty
    graph = build_graph([:a, :b], [[:a, :b]])
    assert_empty graph.descendants(:b)
  end

  # --- Subgraph ---

  def test_subgraph_keeps_only_specified_nodes
    graph = build_graph([:a, :b, :c, :d], [[:a, :b], [:b, :c], [:c, :d]])
    sub = graph.subgraph([:b, :c])

    assert_equal 2, sub.size
    assert sub.edge?(:b, :c)
    refute sub.node?(:a)
    refute sub.node?(:d)
  end

  def test_subgraph_drops_cross_boundary_edges
    graph = build_graph([:a, :b, :c], [[:a, :b], [:b, :c]])
    sub = graph.subgraph([:a, :c])

    assert_equal 2, sub.size
    assert_equal 0, sub.edges.size
  end

  def test_subgraph_rejects_unknown_nodes
    graph = build_graph([:a], [])
    assert_raises(ArgumentError) { graph.subgraph([:a, :missing]) }
  end

  # --- Flat topological sort ---

  def test_topological_sort_linear
    graph = build_graph([:a, :b, :c], [[:a, :b], [:b, :c]])
    assert_equal [:a, :b, :c], graph.topological_sort
  end

  def test_topological_sort_diamond
    graph = build_graph([:a, :b, :c, :d], [[:a, :b], [:a, :c], [:b, :d], [:c, :d]])
    order = graph.topological_sort
    assert_equal :a, order.first
    assert_equal :d, order.last
    assert order.index(:b) < order.index(:d)
    assert order.index(:c) < order.index(:d)
  end

  def test_topological_sort_independent_is_sorted
    graph = build_graph([:c, :b, :a], [])
    assert_equal [:a, :b, :c], graph.topological_sort
  end

  def test_topological_sort_empty_graph
    assert_equal [], DAG::Graph.new.topological_sort
  end

  # --- path? ---

  def test_path_exists_direct
    graph = build_graph([:a, :b], [[:a, :b]])
    assert graph.path?(:a, :b)
  end

  def test_path_exists_transitive
    graph = build_graph([:a, :b, :c], [[:a, :b], [:b, :c]])
    assert graph.path?(:a, :c)
  end

  def test_path_does_not_exist
    graph = build_graph([:a, :b, :c, :d], [[:a, :b], [:c, :d]])
    refute graph.path?(:a, :d)
  end

  def test_path_reverse_does_not_exist
    graph = build_graph([:a, :b], [[:a, :b]])
    refute graph.path?(:b, :a)
  end

  def test_path_reflexive
    graph = build_graph([:a], [])
    assert graph.path?(:a, :a)
  end

  def test_path_nonexistent_same_node
    graph = build_graph([:a], [])
    refute graph.path?(:ghost, :ghost)
  end

  def test_path_nonexistent_different_nodes
    graph = build_graph([:a], [])
    refute graph.path?(:ghost, :phantom)
  end

  def test_path_one_exists_one_missing
    graph = build_graph([:a, :b], [[:a, :b]])
    refute graph.path?(:a, :ghost)
  end

  # --- indegree / outdegree ---

  def test_indegree
    graph = build_graph([:a, :b, :c], [[:a, :c], [:b, :c]])
    assert_equal 0, graph.indegree(:a)
    assert_equal 2, graph.indegree(:c)
  end

  def test_outdegree
    graph = build_graph([:a, :b, :c], [[:a, :b], [:a, :c]])
    assert_equal 2, graph.outdegree(:a)
    assert_equal 0, graph.outdegree(:b)
  end

  # --- each_node / each_edge ---

  def test_each_node
    graph = build_graph([:a, :b, :c], [[:a, :b]])
    collected = []
    graph.each_node { |n| collected << n }
    assert_equal [:a, :b, :c], collected.sort
  end

  def test_each_node_returns_enumerator
    graph = build_graph([:a], [])
    assert_instance_of Enumerator, graph.each_node
  end

  def test_each_edge
    graph = build_graph([:a, :b, :c], [[:a, :b], [:a, :c]])
    collected = []
    graph.each_edge { |e| collected << e }
    assert_equal 2, collected.size
    assert collected.all? { |e| e.is_a?(DAG::Edge) }
  end

  def test_each_edge_returns_enumerator
    graph = DAG::Graph.new
    assert_instance_of Enumerator, graph.each_edge
  end

  # --- Immutability after freeze ---

  def test_frozen_graph_rejects_add_node
    graph = build_graph([:a], [])
    graph.freeze
    assert_raises(FrozenError) { graph.add_node(:b) }
  end

  def test_frozen_graph_rejects_add_edge
    graph = build_graph([:a, :b], [])
    graph.freeze
    assert_raises(FrozenError) { graph.add_edge(:a, :b) }
  end

  def test_frozen_graph_queries_still_work
    graph = build_graph([:a, :b, :c], [[:a, :b], [:b, :c]])
    graph.freeze

    assert_equal 3, graph.size
    assert graph.node?(:a)
    assert graph.edge?(:a, :b)
    assert_equal [[:a], [:b], [:c]], graph.topological_layers
    assert_equal [:a, :b, :c], graph.topological_sort
    assert graph.path?(:a, :c)
  end

  def test_frozen_graph_nodes_not_externally_mutable
    graph = build_graph([:a], [])
    graph.freeze
    assert_raises(FrozenError) { graph.nodes << :hack }
  end

  # --- dup (unfrozen copy) ---

  def test_dup_returns_unfrozen_copy
    graph = build_graph([:a, :b], [[:a, :b]])
    graph.freeze
    copy = graph.dup

    refute copy.frozen?
    assert copy.node?(:a)
    assert copy.edge?(:a, :b)
  end

  def test_dup_is_independent
    graph = build_graph([:a, :b], [[:a, :b]])
    copy = graph.dup
    copy.add_node(:c)
    copy.add_edge(:b, :c)

    refute graph.node?(:c)
    assert copy.node?(:c)
  end

  def test_dup_preserves_structure
    graph = build_graph([:a, :b, :c, :d], [[:a, :b], [:a, :c], [:b, :d], [:c, :d]])
    copy = graph.dup

    assert_equal graph.topological_layers, copy.topological_layers
    assert_equal graph.size, copy.size
    assert_equal graph.edges.size, copy.edges.size
  end

  def test_dup_of_frozen_graph_is_fully_mutable
    graph = build_graph([:a, :b], [[:a, :b]])
    graph.freeze
    copy = graph.dup

    copy.add_node(:c)
    copy.add_edge(:b, :c)

    assert copy.node?(:c)
    assert copy.edge?(:b, :c)
    assert_equal [[:a], [:b], [:c]], copy.topological_layers
  end

  # --- Immutable builders (with_node / with_edge) ---

  def test_with_node_returns_new_frozen_graph
    graph = build_graph([:a, :b], [[:a, :b]])
    graph.freeze
    new_graph = graph.with_node(:c)

    assert new_graph.frozen?
    assert new_graph.node?(:c)
    assert_equal 3, new_graph.size
    refute graph.node?(:c)
    assert_equal 2, graph.size
  end

  def test_with_edge_returns_new_frozen_graph
    graph = build_graph([:a, :b, :c], [[:a, :b]])
    graph.freeze
    new_graph = graph.with_edge(:b, :c)

    assert new_graph.frozen?
    assert new_graph.edge?(:b, :c)
    refute graph.edge?(:b, :c)
  end

  def test_with_node_on_mutable_graph
    graph = build_graph([:a], [])
    new_graph = graph.with_node(:b)

    assert new_graph.frozen?
    assert new_graph.node?(:b)
    refute graph.node?(:b)
  end

  def test_with_edge_rejects_cycle
    graph = build_graph([:a, :b], [[:a, :b]])
    graph.freeze
    assert_raises(DAG::CycleError) { graph.with_edge(:b, :a) }
  end

  # --- to_h ---

  def test_to_h_returns_nodes_and_edges
    graph = build_graph([:a, :b], [[:a, :b]])
    h = graph.to_h

    assert_equal [:a, :b], h[:nodes]
    assert_equal [{from: :a, to: :b}], h[:edges]
  end

  def test_to_h_empty_graph
    h = DAG::Graph.new.to_h
    assert_equal({nodes: [], edges: []}, h)
  end

  # --- Edge data type ---

  def test_edge_is_frozen
    edge = DAG::Edge.new(from: :a, to: :b)
    assert edge.frozen?
    assert_equal :a, edge.from
    assert_equal :b, edge.to
  end

  # --- Equality ---

  def test_equality_same_structure
    g1 = build_graph([:a, :b], [[:a, :b]])
    g2 = build_graph([:a, :b], [[:a, :b]])
    assert_equal g1, g2
  end

  def test_equality_different_structure
    g1 = build_graph([:a, :b], [[:a, :b]])
    g2 = build_graph([:a, :b, :c], [[:a, :b]])
    refute_equal g1, g2
  end

  def test_equality_with_non_graph
    graph = build_graph([:a], [])
    refute_equal graph, "not a graph"
  end

  def test_hash_same_for_equal_graphs
    g1 = build_graph([:a, :b], [[:a, :b]])
    g2 = build_graph([:a, :b], [[:a, :b]])
    assert_equal g1.hash, g2.hash
  end

  # --- remove_node / remove_edge ---

  def test_remove_node_removes_node_and_incident_edges
    graph = build_graph([:a, :b, :c], [[:a, :b], [:b, :c]])
    graph.remove_node(:b)

    refute graph.node?(:b)
    assert_equal 2, graph.size
    assert_equal 0, graph.edges.size
  end

  def test_remove_node_unknown_raises
    graph = build_graph([:a], [])
    assert_raises(DAG::UnknownNodeError) { graph.remove_node(:missing) }
  end

  def test_remove_edge_keeps_both_nodes
    graph = build_graph([:a, :b], [[:a, :b]])
    graph.remove_edge(:a, :b)

    assert graph.node?(:a)
    assert graph.node?(:b)
    refute graph.edge?(:a, :b)
  end

  def test_remove_edge_unknown_raises
    graph = build_graph([:a, :b], [])
    assert_raises(DAG::UnknownNodeError) { graph.remove_edge(:a, :b) }
  end

  def test_frozen_graph_rejects_remove_node
    graph = build_graph([:a], [])
    graph.freeze
    assert_raises(FrozenError) { graph.remove_node(:a) }
  end

  def test_frozen_graph_rejects_remove_edge
    graph = build_graph([:a, :b], [[:a, :b]])
    graph.freeze
    assert_raises(FrozenError) { graph.remove_edge(:a, :b) }
  end

  def test_topological_sort_after_removal
    graph = build_graph([:a, :b, :c, :d], [[:a, :b], [:b, :c], [:a, :d]])
    graph.remove_node(:b)

    assert_equal [[:a, :c], [:d]], graph.topological_layers
  end

  # --- without_node / without_edge ---

  def test_without_node_returns_new_frozen_graph
    graph = build_graph([:a, :b, :c], [[:a, :b], [:b, :c]])
    graph.freeze
    new_graph = graph.without_node(:b)

    assert new_graph.frozen?
    refute new_graph.node?(:b)
    assert_equal 2, new_graph.size
    assert_equal 0, new_graph.edges.size
  end

  def test_without_node_original_unchanged
    graph = build_graph([:a, :b], [[:a, :b]])
    graph.without_node(:b)

    assert graph.node?(:b)
    assert graph.edge?(:a, :b)
  end

  def test_without_node_on_mutable_graph
    graph = build_graph([:a, :b], [[:a, :b]])
    new_graph = graph.without_node(:b)

    assert new_graph.frozen?
    refute new_graph.node?(:b)
    assert graph.node?(:b)
  end

  def test_without_node_unknown_raises
    graph = build_graph([:a], [])
    assert_raises(DAG::UnknownNodeError) { graph.without_node(:missing) }
  end

  def test_without_edge_returns_new_frozen_graph
    graph = build_graph([:a, :b], [[:a, :b]])
    graph.freeze
    new_graph = graph.without_edge(:a, :b)

    assert new_graph.frozen?
    refute new_graph.edge?(:a, :b)
    assert new_graph.node?(:a)
    assert new_graph.node?(:b)
  end

  def test_without_edge_original_unchanged
    graph = build_graph([:a, :b], [[:a, :b]])
    graph.without_edge(:a, :b)

    assert graph.edge?(:a, :b)
  end

  def test_without_edge_unknown_raises
    graph = build_graph([:a, :b], [])
    assert_raises(DAG::UnknownNodeError) { graph.without_edge(:a, :b) }
  end

  # --- replace_node / with_node_replaced ---

  def test_replace_node_renames_and_rewires_chain
    graph = build_graph([:a, :b, :c], [[:a, :b], [:b, :c]])
    graph.replace_node(:b, :x)

    assert graph.node?(:x)
    refute graph.node?(:b)
    assert graph.edge?(:a, :x)
    assert graph.edge?(:x, :c)
    assert_equal 3, graph.size
    assert_equal 2, graph.edges.size
  end

  def test_replace_node_renames_root
    graph = build_graph([:a, :b], [[:a, :b]])
    graph.replace_node(:a, :x)

    assert graph.node?(:x)
    refute graph.node?(:a)
    assert graph.edge?(:x, :b)
  end

  def test_replace_node_renames_leaf
    graph = build_graph([:a, :b], [[:a, :b]])
    graph.replace_node(:b, :x)

    assert graph.node?(:x)
    refute graph.node?(:b)
    assert graph.edge?(:a, :x)
  end

  def test_replace_node_isolated
    graph = build_graph([:a], [])
    graph.replace_node(:a, :x)

    assert graph.node?(:x)
    refute graph.node?(:a)
    assert_equal 1, graph.size
  end

  def test_replace_node_diamond
    graph = build_graph([:a, :b, :c, :d], [[:a, :b], [:a, :c], [:b, :d], [:c, :d]])
    graph.replace_node(:b, :x)

    assert graph.edge?(:a, :x)
    assert graph.edge?(:x, :d)
    assert graph.edge?(:a, :c)
    assert graph.edge?(:c, :d)
    assert_equal 4, graph.edges.size
  end

  def test_replace_node_same_name_is_noop
    graph = build_graph([:a, :b], [[:a, :b]])
    graph.replace_node(:a, :a)

    assert graph.node?(:a)
    assert graph.edge?(:a, :b)
    assert_equal 2, graph.size
  end

  def test_replace_node_preserves_edge_metadata
    graph = build_graph([:a, :b, :c], [])
    graph.add_edge(:a, :b, weight: 5)
    graph.add_edge(:b, :c, weight: 3)
    graph.replace_node(:b, :x)

    assert_equal({weight: 5}, graph.edge_metadata(:a, :x))
    assert_equal({weight: 3}, graph.edge_metadata(:x, :c))
  end

  def test_replace_node_unknown_raises
    graph = build_graph([:a], [])
    assert_raises(DAG::UnknownNodeError) { graph.replace_node(:missing, :x) }
  end

  def test_replace_node_duplicate_raises
    graph = build_graph([:a, :b], [])
    assert_raises(DAG::DuplicateNodeError) { graph.replace_node(:a, :b) }
  end

  def test_frozen_graph_rejects_replace_node
    graph = build_graph([:a, :b], [[:a, :b]])
    graph.freeze
    assert_raises(FrozenError) { graph.replace_node(:a, :x) }
  end

  def test_with_node_replaced_returns_new_frozen_graph
    graph = build_graph([:a, :b, :c], [[:a, :b], [:b, :c]])
    graph.freeze
    new_graph = graph.with_node_replaced(:b, :x)

    assert new_graph.frozen?
    assert new_graph.node?(:x)
    refute new_graph.node?(:b)
    assert new_graph.edge?(:a, :x)
    assert new_graph.edge?(:x, :c)
  end

  def test_with_node_replaced_original_unchanged
    graph = build_graph([:a, :b], [[:a, :b]])
    graph.with_node_replaced(:b, :x)

    assert graph.node?(:b)
    refute graph.node?(:x)
  end

  def test_with_node_replaced_preserves_edge_metadata
    graph = build_graph([:a, :b, :c], [])
    graph.add_edge(:a, :b, weight: 7)
    graph.add_edge(:b, :c, weight: 2)
    new_graph = graph.with_node_replaced(:b, :x)

    assert_equal({weight: 7}, new_graph.edge_metadata(:a, :x))
    assert_equal({weight: 2}, new_graph.edge_metadata(:x, :c))
  end

  # --- Enumerable ---

  def test_enumerable_map
    graph = build_graph([:a, :b, :c], [])
    assert_equal [:a, :b, :c], graph.map { |n| n }.sort
  end

  def test_enumerable_select
    graph = build_graph([:a, :b, :c], [[:a, :b]])
    roots = graph.select { |n| graph.indegree(n) == 0 }
    assert_includes roots, :a
    assert_includes roots, :c
  end

  def test_enumerable_count
    graph = build_graph([:a, :b, :c], [])
    assert_equal 3, graph.count
  end

  def test_enumerable_include
    graph = build_graph([:a, :b], [])
    assert graph.include?(:a)
    refute graph.include?(:z)
  end

  # --- incoming_edges ---

  def test_incoming_edges_on_root
    graph = build_graph([:a, :b], [[:a, :b]])
    assert_empty graph.incoming_edges(:a)
  end

  def test_incoming_edges_on_sink
    graph = build_graph([:a, :b, :c], [[:a, :c], [:b, :c]])
    edges = graph.incoming_edges(:c)
    assert_equal 2, edges.size
    assert edges.all? { |e| e.to == :c }
    assert_equal [:a, :b], edges.map(&:from).sort
  end

  # --- Edge metadata ---

  def test_add_edge_with_metadata
    graph = build_graph([:a, :b], [])
    graph.add_edge(:a, :b, weight: 5)
    assert_equal({weight: 5}, graph.edge_metadata(:a, :b))
  end

  def test_edge_metadata_default_empty
    graph = build_graph([:a, :b], [[:a, :b]])
    assert_equal({}, graph.edge_metadata(:a, :b))
  end

  def test_edge_weight_convenience
    graph = build_graph([:a, :b], [])
    graph.add_edge(:a, :b, weight: 3)
    edge = graph.edges.first
    assert_equal 3, edge.weight
  end

  def test_edge_weight_default
    graph = build_graph([:a, :b], [[:a, :b]])
    edge = graph.edges.first
    assert_equal 1, edge.weight
  end

  def test_edge_metadata_preserved_in_dup
    graph = build_graph([:a, :b], [])
    graph.add_edge(:a, :b, weight: 7)
    duped = graph.dup
    assert_equal({weight: 7}, duped.edge_metadata(:a, :b))
  end

  def test_edge_metadata_in_subgraph
    graph = build_graph([:a, :b, :c], [])
    graph.add_edge(:a, :b, weight: 2)
    graph.add_edge(:b, :c, weight: 3)
    sub = graph.subgraph([:a, :b])
    assert_equal({weight: 2}, sub.edge_metadata(:a, :b))
  end

  # --- Frozen graph caching ---

  def test_frozen_graph_caches_topological_layers
    graph = build_graph([:a, :b], [[:a, :b]])
    graph.freeze
    assert_same graph.topological_layers, graph.topological_layers
  end

  def test_frozen_graph_caches_roots
    graph = build_graph([:a, :b], [[:a, :b]])
    graph.freeze
    assert_same graph.roots, graph.roots
  end

  def test_frozen_graph_caches_leaves
    graph = build_graph([:a, :b], [[:a, :b]])
    graph.freeze
    assert_same graph.leaves, graph.leaves
  end

  def test_mutable_graph_does_not_cache
    graph = build_graph([:a, :b], [[:a, :b]])
    refute_same graph.topological_layers, graph.topological_layers
  end

  def test_edge_metadata_removed_on_remove_edge
    graph = build_graph([:a, :b], [])
    graph.add_edge(:a, :b, weight: 5)
    graph.remove_edge(:a, :b)
    assert_equal({}, graph.edge_metadata(:a, :b))
  end

  # --- Shortest / longest path ---

  def test_shortest_path_linear_chain
    graph = build_graph([:a, :b, :c], [[:a, :b], [:b, :c]])
    result = graph.shortest_path(:a, :c)
    assert_equal({cost: 2, path: [:a, :b, :c]}, result)
  end

  def test_shortest_path_diamond_with_weights
    graph = build_graph([:a, :b, :c, :d], [])
    graph.add_edge(:a, :b, weight: 1)
    graph.add_edge(:a, :c, weight: 10)
    graph.add_edge(:b, :d, weight: 1)
    graph.add_edge(:c, :d, weight: 1)
    result = graph.shortest_path(:a, :d)
    assert_equal 2, result[:cost]
    assert_equal [:a, :b, :d], result[:path]
  end

  def test_shortest_path_unreachable
    graph = build_graph([:a, :b], [])
    assert_nil graph.shortest_path(:a, :b)
  end

  def test_shortest_path_same_node
    graph = build_graph([:a], [])
    assert_equal({cost: 0, path: [:a]}, graph.shortest_path(:a, :a))
  end

  def test_longest_path_linear_chain
    graph = build_graph([:a, :b, :c], [[:a, :b], [:b, :c]])
    result = graph.longest_path(:a, :c)
    assert_equal({cost: 2, path: [:a, :b, :c]}, result)
  end

  def test_longest_path_diamond_picks_longer
    graph = build_graph([:a, :b, :c, :d], [])
    graph.add_edge(:a, :b, weight: 1)
    graph.add_edge(:a, :c, weight: 10)
    graph.add_edge(:b, :d, weight: 1)
    graph.add_edge(:c, :d, weight: 1)
    result = graph.longest_path(:a, :d)
    assert_equal 11, result[:cost]
    assert_equal [:a, :c, :d], result[:path]
  end

  def test_longest_path_unreachable
    graph = build_graph([:a, :b], [])
    assert_nil graph.longest_path(:a, :b)
  end

  # --- Critical path ---

  def test_critical_path_linear_chain
    graph = build_graph([:a, :b, :c], [[:a, :b], [:b, :c]])
    result = graph.critical_path
    assert_equal({cost: 2, path: [:a, :b, :c]}, result)
  end

  def test_critical_path_diamond_picks_longest_branch
    graph = build_graph([:a, :b, :c, :d], [])
    graph.add_edge(:a, :b, weight: 1)
    graph.add_edge(:a, :c, weight: 10)
    graph.add_edge(:b, :d, weight: 1)
    graph.add_edge(:c, :d, weight: 1)
    result = graph.critical_path
    assert_equal 11, result[:cost]
    assert_equal [:a, :c, :d], result[:path]
  end

  def test_critical_path_single_node
    graph = build_graph([:a], [])
    result = graph.critical_path
    assert_equal({cost: 0, path: [:a]}, result)
  end

  def test_critical_path_empty_graph
    graph = DAG::Graph.new
    assert_nil graph.critical_path
  end

  def test_critical_path_parallel_branches
    graph = build_graph([:a, :b, :c, :d, :e], [])
    graph.add_edge(:a, :b, weight: 5)
    graph.add_edge(:a, :c, weight: 2)
    graph.add_edge(:b, :d, weight: 3)
    graph.add_edge(:c, :e, weight: 1)
    result = graph.critical_path
    assert_equal 8, result[:cost]
    assert_equal [:a, :b, :d], result[:path]
  end

  # --- to_dot ---

  def test_to_dot_simple_graph
    graph = build_graph([:a, :b], [[:a, :b]])
    expected = <<~DOT.chomp
      digraph dag {
        a;
        b;
        a -> b;
      }
    DOT
    assert_equal expected, graph.to_dot
  end

  def test_to_dot_with_custom_name
    graph = build_graph([:a], [])
    assert_match(/digraph my_dag \{/, graph.to_dot(name: "my_dag"))
  end

  def test_to_dot_empty_graph
    graph = DAG::Graph.new
    assert_equal "digraph dag {\n}", graph.to_dot
  end

  def test_to_dot_with_edge_metadata
    graph = build_graph([:a, :b], [])
    graph.add_edge(:a, :b, weight: 3)
    assert_match(/a -> b \[label="weight=3"\]/, graph.to_dot)
  end

  # --- Empty graph ---

  def test_empty_graph
    graph = DAG::Graph.new
    assert graph.empty?
    assert_equal 0, graph.size
  end

  private

  def build_graph(nodes, edges)
    g = nodes.reduce(DAG::Graph.new) { |graph, n| graph.add_node(n) }
    edges.each { |from, to| g.add_edge(from, to) }
    g
  end
end
