# frozen_string_literal: true

require_relative "test_helper"

# Property-based fuzz tests for DAG::Graph. Methodology (loosely after
# GraphFuzz, arxiv 2502.15160): algorithm-specific invariants as feedback
# instead of code coverage, plus differential checks against hand-rolled
# reference implementations.
#
#   DAG_FUZZ_SEED=12345 DAG_FUZZ_ITERATIONS=2000 \
#     bundle exec rake test TEST=spec/graph_fuzz_test.rb
class GraphFuzzTest < Minitest::Test
  DEFAULT_SEED = 20_260_407
  DEFAULT_ITERATIONS = 200
  MAX_NODES = 12
  MAX_EDGE_ATTEMPTS = 30

  def setup
    @seed = ENV.fetch("DAG_FUZZ_SEED", DEFAULT_SEED.to_s).to_i
    @rng = Random.new(@seed)
    @iterations = ENV.fetch("DAG_FUZZ_ITERATIONS", DEFAULT_ITERATIONS.to_s).to_i
  end

  # If add_edge raises, every internal graph structure must match the
  # pre-call snapshot.
  def test_add_edge_is_atomic
    fuzz_iterate do
      graph = build_random_graph
      nodes = graph.each_node.to_a
      next if nodes.empty?

      snapshot = internal_graph_state(graph)
      from = nodes.sample(random: @rng)
      to = nodes.sample(random: @rng)

      begin
        graph.add_edge(from, to, **random_edge_metadata)
      rescue DAG::Error
        assert_equal snapshot, internal_graph_state(graph)
      end
    end
  end

  # For every edge u->v, u must come strictly before v in topological_sort.
  def test_topological_sort_respects_every_edge
    fuzz_iterate do
      graph = build_random_graph
      position = graph.topological_sort.each_with_index.to_h
      graph.each_edge do |edge|
        assert position[edge.from] < position[edge.to],
          "edge #{edge.from} -> #{edge.to} violates topological order"
      end
    end
  end

  def test_topological_layers_are_antichains_and_cover_nodes
    fuzz_iterate do
      graph = build_random_graph
      layers = graph.topological_layers

      assert_equal graph.each_node.to_a.sort, layers.flatten.sort

      if graph.empty?
        assert_empty layers
        next
      end

      assert_equal graph.roots, layers.first.to_set

      layer_of = {}
      layers.each_with_index do |layer, index|
        layer.each { |node| layer_of[node] = index }
        layer.combination(2) do |u, v|
          refute graph.path?(u, v), "#{u} and #{v} share a layer but #{u} reaches #{v}"
          refute graph.path?(v, u), "#{u} and #{v} share a layer but #{v} reaches #{u}"
        end
      end

      graph.each_edge do |edge|
        assert layer_of[edge.from] < layer_of[edge.to],
          "edge #{edge.from} -> #{edge.to} does not advance layers"
      end
    end
  end

  # Differential check against a hand-rolled BFS that doesn't reuse the
  # internal `reachable?` walker shared by `path?` / `descendants`.
  def test_path_agrees_with_descendants_and_naive_bfs
    fuzz_iterate do
      graph = build_random_graph
      nodes = graph.each_node.to_a
      next if nodes.empty?

      node = nodes.sample(random: @rng)
      assert graph.path?(node, node)
      assert naive_reachable?(graph, node, node)

      next if nodes.size < 2

      a, b = nodes.sample(2, random: @rng)
      graph_says = graph.path?(a, b)
      assert_equal graph_says, graph.descendants(a).include?(b)
      assert_equal graph_says, naive_reachable?(graph, a, b)
    end
  end

  def test_descendants_and_ancestors_are_symmetric
    fuzz_iterate do
      graph = build_random_graph

      graph.each_node do |a|
        graph.descendants(a).each do |b|
          assert graph.ancestors(b).include?(a),
            "#{b} in descendants(#{a}) but #{a} not in ancestors(#{b})"
        end
      end

      graph.each_node do |b|
        graph.ancestors(b).each do |a|
          assert graph.descendants(a).include?(b),
            "#{a} in ancestors(#{b}) but #{b} not in descendants(#{a})"
        end
      end
    end
  end

  def test_replace_node_preserves_edges_and_metadata
    fuzz_iterate do |i|
      graph = build_random_graph
      nodes = graph.each_node.to_a
      next if nodes.empty?

      old_name = nodes.sample(random: @rng)
      new_name = :"renamed_#{i}"
      edge_count = graph.edge_count
      incoming = graph.predecessors(old_name).to_a.sort
      outgoing = graph.successors(old_name).to_a.sort
      incoming_metadata = incoming.to_h { |pred| [pred, graph.edge_metadata(pred, old_name)] }
      outgoing_metadata = outgoing.to_h { |succ| [succ, graph.edge_metadata(old_name, succ)] }

      graph.replace_node(old_name, new_name)

      refute graph.node?(old_name)
      assert graph.node?(new_name)
      assert_equal edge_count, graph.edge_count
      assert_equal incoming, graph.predecessors(new_name).to_a.sort
      assert_equal outgoing, graph.successors(new_name).to_a.sort
      incoming_metadata.each do |pred, metadata|
        assert_equal metadata, graph.edge_metadata(pred, new_name)
      end
      outgoing_metadata.each do |succ, metadata|
        assert_equal metadata, graph.edge_metadata(new_name, succ)
      end
    end
  end

  # Every edge in subgraph(S) has both endpoints in S, every original
  # edge with both endpoints in S is preserved, and no kept node is lost.
  def test_subgraph_is_closed_complete_and_preserves_metadata
    fuzz_iterate do
      graph = build_random_graph
      nodes = graph.each_node.to_a
      keep = nodes.sample(@rng.rand(0..nodes.size), random: @rng).to_set
      sub = graph.subgraph(keep)

      assert_equal keep.to_a.sort, sub.each_node.to_a.sort

      sub.each_edge do |edge|
        assert keep.include?(edge.from)
        assert keep.include?(edge.to)
      end

      graph.each_edge do |edge|
        next unless keep.include?(edge.from) && keep.include?(edge.to)

        assert sub.edge?(edge.from, edge.to), "subgraph dropped #{edge.from} -> #{edge.to}"
        assert_equal edge.metadata, sub.edge_metadata(edge.from, edge.to)
      end
    end
  end

  def test_edge_and_node_counts_match_iteration
    fuzz_iterate do
      graph = build_random_graph
      assert_equal graph.each_edge.count, graph.edge_count
      assert_equal graph.each_node.count, graph.node_count
    end
  end

  def test_indegree_and_outdegree_match_neighbors
    fuzz_iterate do
      graph = build_random_graph
      graph.each_node do |node|
        assert_equal graph.predecessors(node).size, graph.indegree(node)
        assert_equal graph.successors(node).size, graph.outdegree(node)
      end
    end
  end

  def test_each_predecessor_matches_predecessors
    fuzz_iterate do
      graph = build_random_graph
      graph.each_node do |node|
        assert_equal graph.predecessors(node), graph.each_predecessor(node).to_set
      end
    end
  end

  def test_incoming_edges_match_each_edge_filter
    fuzz_iterate do
      graph = build_random_graph
      graph.each_node do |node|
        expected = graph.each_edge.select { |edge| edge.to == node }.to_set
        assert_equal expected, graph.incoming_edges(node)
      end
    end
  end

  def test_structural_equality_is_order_insensitive_and_metadata_sensitive
    fuzz_iterate do
      a = build_random_graph
      b = DAG::Graph.new
      a.each_node.to_a.shuffle(random: @rng).each { |node| b.add_node(node) }
      a.each_edge.to_a.shuffle(random: @rng).each { |edge| b.add_edge(edge.from, edge.to, **edge.metadata) }

      assert_equal a, b
      assert_equal a.hash, b.hash

      metadata_edge = a.each_edge.find { |edge| !edge.metadata.empty? }
      next unless metadata_edge

      c = DAG::Graph.new
      c_nodes = a.each_node.to_a.shuffle(random: @rng)
      c_nodes.each { |node| c.add_node(node) }
      a.each_edge.to_a.shuffle(random: @rng).each do |edge|
        metadata =
          if edge == metadata_edge
            edge.metadata.merge(weight: edge.metadata.fetch(:weight, 1) + 1)
          else
            edge.metadata
          end
        c.add_edge(edge.from, edge.to, **metadata)
      end

      refute_equal a, c
    end
  end

  # freeze.freeze == freeze, and every eagerly-cached view matches the live
  # mutable twin.
  def test_freeze_is_idempotent
    fuzz_iterate do
      graph = build_random_graph
      twin = graph.dup
      graph.freeze

      assert_same graph, graph.freeze
      assert_equal twin, graph
      assert_equal twin.topological_layers, graph.topological_layers
      assert_equal twin.topological_sort, graph.topological_sort
      assert_equal twin.roots, graph.roots
      assert_equal twin.leaves, graph.leaves
      assert_equal twin.edges, graph.edges
    end
  end

  def test_remove_then_re_add_edge_round_trips
    fuzz_iterate do
      graph = build_random_graph
      edges = graph.each_edge.to_a
      next if edges.empty?

      edge = edges.sample(random: @rng)
      original = graph.dup
      graph.remove_edge(edge.from, edge.to)
      graph.add_edge(edge.from, edge.to, **edge.metadata)
      assert_equal original, graph
    end
  end

  def test_remove_node_removes_all_incident_edges
    fuzz_iterate do
      graph = build_random_graph
      nodes = graph.each_node.to_a
      next if nodes.empty?

      removed = nodes.sample(random: @rng)
      expected_nodes = nodes - [removed]
      expected_edges = edge_dump(graph).reject { |from, to, _| from == removed || to == removed }

      graph.remove_node(removed)

      refute graph.node?(removed)
      assert_equal expected_nodes.sort, graph.each_node.to_a.sort
      assert_equal expected_edges, edge_dump(graph)
      expected_nodes.each do |node|
        refute_includes graph.predecessors(node), removed
        refute_includes graph.successors(node), removed
      end
    end
  end

  def test_shortest_path_matches_naive_relaxation
    fuzz_iterate do
      graph = build_random_graph
      nodes = graph.each_node.to_a
      next if nodes.empty?

      from = nodes.sample(random: @rng)
      to = nodes.sample(random: @rng)
      expected = naive_weighted_path(graph, from, to, maximize: false)
      actual = graph.shortest_path(from, to)

      if expected.nil?
        assert_nil actual
      else
        refute_nil actual
        assert_equal expected[:cost], actual[:cost]
      end
      assert_valid_weighted_path(graph, actual, from: from, to: to) if actual
    end
  end

  def test_longest_path_matches_naive_relaxation
    fuzz_iterate do
      graph = build_random_graph
      nodes = graph.each_node.to_a
      next if nodes.empty?

      from = nodes.sample(random: @rng)
      to = nodes.sample(random: @rng)
      expected = naive_weighted_path(graph, from, to, maximize: true)
      actual = graph.longest_path(from, to)

      if expected.nil?
        assert_nil actual
      else
        refute_nil actual
        assert_equal expected[:cost], actual[:cost]
      end
      assert_valid_weighted_path(graph, actual, from: from, to: to) if actual
    end
  end

  def test_critical_path_matches_naive_relaxation
    fuzz_iterate do
      graph = build_random_graph
      expected = naive_critical_path(graph)
      actual = graph.critical_path

      if expected.nil?
        assert_nil actual
      else
        refute_nil actual
        assert_equal expected[:cost], actual[:cost]
      end
      next unless actual

      assert_includes graph.roots, actual[:path].first
      assert_includes graph.leaves, actual[:path].last
      assert_valid_weighted_path(graph, actual, from: actual[:path].first, to: actual[:path].last)
    end
  end

  def test_with_node_is_pure_and_frozen
    fuzz_iterate do |i|
      graph = build_random_graph
      original = graph.dup
      new_name = :"with_node_#{i}"

      result = graph.with_node(new_name)

      assert_equal original, graph
      assert result.frozen?
      assert result.node?(new_name)
      refute graph.node?(new_name)
    end
  end

  def test_with_edge_is_pure_and_frozen
    fuzz_iterate do
      graph = build_random_graph
      from, to = addable_edge_candidate(graph)
      next unless from

      metadata = random_edge_metadata
      original = graph.dup
      result = graph.with_edge(from, to, **metadata)

      assert_equal original, graph
      assert result.frozen?
      assert result.edge?(from, to)
      assert_equal metadata, result.edge_metadata(from, to)
    end
  end

  def test_without_node_is_pure_and_frozen
    fuzz_iterate do
      graph = build_random_graph
      nodes = graph.each_node.to_a
      next if nodes.empty?

      removed = nodes.sample(random: @rng)
      original = graph.dup
      result = graph.without_node(removed)

      assert_equal original, graph
      assert result.frozen?
      refute result.node?(removed)
    end
  end

  def test_without_edge_is_pure_and_frozen
    fuzz_iterate do
      graph = build_random_graph
      edge = graph.each_edge.to_a.sample(random: @rng)
      next unless edge

      original = graph.dup
      result = graph.without_edge(edge.from, edge.to)

      assert_equal original, graph
      assert result.frozen?
      refute result.edge?(edge.from, edge.to)
    end
  end

  def test_with_node_replaced_is_pure_and_frozen
    fuzz_iterate do |i|
      graph = build_random_graph
      nodes = graph.each_node.to_a
      next if nodes.empty?

      old_name = nodes.sample(random: @rng)
      new_name = :"with_replaced_#{i}"
      incoming = graph.predecessors(old_name).to_a.sort
      outgoing = graph.successors(old_name).to_a.sort
      incoming_metadata = incoming.to_h { |pred| [pred, graph.edge_metadata(pred, old_name)] }
      outgoing_metadata = outgoing.to_h { |succ| [succ, graph.edge_metadata(old_name, succ)] }
      original = graph.dup
      result = graph.with_node_replaced(old_name, new_name)

      assert_equal original, graph
      assert result.frozen?
      refute result.node?(old_name)
      assert result.node?(new_name)
      assert_equal incoming, result.predecessors(new_name).to_a.sort
      assert_equal outgoing, result.successors(new_name).to_a.sort
      incoming_metadata.each do |pred, metadata|
        assert_equal metadata, result.edge_metadata(pred, new_name)
      end
      outgoing_metadata.each do |succ, metadata|
        assert_equal metadata, result.edge_metadata(new_name, succ)
      end
    end
  end

  def test_to_h_matches_graph_structure
    fuzz_iterate do
      graph = build_random_graph
      dumped = graph.to_h

      assert_equal graph.each_node.to_a.sort, dumped[:nodes]
      assert_equal edge_hash_dump(graph), normalize_edge_hashes(dumped[:edges])
    end
  end

  def test_to_dot_and_inspect_include_structure
    fuzz_iterate do
      graph = build_random_graph
      dot = graph.to_dot

      assert_match(/\Adigraph dag \{/, dot)
      graph.each_node do |node|
        assert_includes dot, "  #{node};"
      end
      graph.each_edge do |edge|
        if edge.metadata.empty?
          assert_includes dot, "  #{edge.from} -> #{edge.to};"
        else
          label = edge.metadata.map { |key, value| "#{key}=#{value}" }.join(", ")
          assert_includes dot, %(  #{edge.from} -> #{edge.to} [label="#{label}"];)
        end
      end

      assert_match(/edges=#{graph.edge_count}>/, graph.inspect)
      assert_equal graph.inspect, graph.to_s
    end
  end

  private

  # Runs the iteration loop, wrapping Minitest failures with the seed +
  # iteration index so a failure can be reproduced via DAG_FUZZ_SEED.
  def fuzz_iterate
    @iterations.times do |i|
      yield i
    rescue Minitest::Assertion => e
      raise e, "[seed=#{@seed} iteration=#{i}] #{e.message}", e.backtrace
    end
  end

  # Builds a random DAG. ~30% of edge attempts target an ancestor of the
  # source so CycleError gets real coverage instead of ~1% from uniform
  # sampling. We also sometimes emit weighted edges so metadata-bearing
  # behavior gets fuzz coverage too.
  def build_random_graph
    graph = DAG::Graph.new
    nodes = (0...@rng.rand(0..MAX_NODES)).map { |i| :"n#{i}" }
    nodes.each { |node| graph.add_node(node) }
    return graph if nodes.empty?

    @rng.rand(0..MAX_EDGE_ATTEMPTS).times do
      from = nodes.sample(random: @rng)
      to =
        if @rng.rand < 0.3 && (ancestors = graph.ancestors(from)).any?
          ancestors.to_a.sample(random: @rng)
        else
          nodes.sample(random: @rng)
        end

      begin
        graph.add_edge(from, to, **random_edge_metadata)
      rescue DAG::CycleError
        # Expected: cycle attempts and self-edges both raise CycleError.
      end
    end

    graph
  end

  def random_edge_metadata
    return {} unless @rng.rand < 0.4
    {weight: @rng.rand(1..9)}
  end

  # Reference reachability via the public successor API. Does not touch
  # the private `reachable?` walker shared by `path?` and `descendants`.
  def naive_reachable?(graph, from, to)
    return true if from == to

    visited = Set.new
    queue = [from]

    until queue.empty?
      current = queue.shift
      next unless visited.add?(current)

      successors = graph.successors(current)
      return true if successors.include?(to)
      queue.concat(successors.to_a)
    end

    false
  end

  def naive_weighted_path(graph, from, to, maximize:)
    from = from.to_sym
    to = to.to_sym
    return nil unless graph.node?(from) && graph.node?(to)
    return {cost: 0, path: [from]} if from == to

    sentinel = maximize ? -Float::INFINITY : Float::INFINITY
    better = maximize ? ->(candidate, current) { candidate > current } : ->(candidate, current) { candidate < current }
    dist = Hash.new(sentinel)
    pred = {}
    dist[from] = 0

    [graph.node_count - 1, 0].max.times do
      updated = false

      graph.each_edge do |edge|
        next if dist[edge.from] == sentinel

        candidate = dist[edge.from] + edge.weight
        next unless better.call(candidate, dist[edge.to])

        dist[edge.to] = candidate
        pred[edge.to] = edge.from
        updated = true
      end

      break unless updated
    end

    return nil if dist[to] == sentinel

    {cost: dist[to], path: rebuild_path(pred, to)}
  end

  def naive_critical_path(graph)
    return nil if graph.empty?

    dist = Hash.new(-Float::INFINITY)
    pred = {}
    graph.roots.each { |root| dist[root] = 0 }

    [graph.node_count - 1, 0].max.times do
      updated = false

      graph.each_edge do |edge|
        next if dist[edge.from] == -Float::INFINITY

        candidate = dist[edge.from] + edge.weight
        next unless candidate > dist[edge.to]

        dist[edge.to] = candidate
        pred[edge.to] = edge.from
        updated = true
      end

      break unless updated
    end

    target = graph.leaves.max_by { |leaf| dist[leaf] }
    {cost: dist[target], path: rebuild_path(pred, target)}
  end

  def rebuild_path(pred, target)
    path = [target]
    path << pred[path.last] while pred.key?(path.last)
    path.reverse
  end

  def assert_valid_weighted_path(graph, result, from:, to:)
    assert_equal from.to_sym, result[:path].first
    assert_equal to.to_sym, result[:path].last
    result[:path].each_cons(2) do |a, b|
      assert graph.edge?(a, b), "path step #{a} -> #{b} is not an edge"
    end
    assert_equal path_cost(graph, result[:path]), result[:cost]
  end

  def path_cost(graph, path)
    path.each_cons(2).sum { |from, to| graph.edge_metadata(from, to).fetch(:weight, 1) }
  end

  def addable_edge_candidate(graph)
    nodes = graph.each_node.to_a.shuffle(random: @rng)

    nodes.each do |from|
      nodes.each do |to|
        next if from == to
        next if graph.edge?(from, to)
        next if graph.path?(to, from)

        return [from, to]
      end
    end

    [nil, nil]
  end

  def edge_dump(graph)
    graph.each_edge.map { |edge| [edge.from, edge.to, edge.metadata] }
      .sort_by { |from, to, metadata| [from.to_s, to.to_s, metadata_sort_key(metadata)] }
  end

  def edge_hash_dump(graph)
    normalize_edge_hashes(
      graph.each_edge.map do |edge|
        hash = {from: edge.from, to: edge.to}
        hash[:metadata] = edge.metadata unless edge.metadata.empty?
        hash
      end
    )
  end

  def normalize_edge_hashes(edges)
    edges.map do |edge|
      normalized = {from: edge.fetch(:from).to_sym, to: edge.fetch(:to).to_sym}
      metadata = edge.fetch(:metadata, {})
      normalized[:metadata] = metadata unless metadata.empty?
      normalized
    end.sort_by { |edge| [edge[:from].to_s, edge[:to].to_s, metadata_sort_key(edge.fetch(:metadata, {}))] }
  end

  def internal_graph_state(graph)
    {
      nodes: graph.instance_variable_get(:@nodes).to_a.sort_by(&:to_s),
      adjacency: normalize_set_hash(graph.instance_variable_get(:@adjacency)),
      reverse: normalize_set_hash(graph.instance_variable_get(:@reverse)),
      edge_metadata: normalize_metadata_hash(graph.instance_variable_get(:@edge_metadata))
    }
  end

  def normalize_set_hash(hash)
    hash.keys.sort_by(&:to_s).to_h do |key|
      [key, hash.fetch(key).to_a.sort_by(&:to_s)]
    end
  end

  def normalize_metadata_hash(hash)
    hash.keys.sort_by(&:to_s).to_h do |from|
      inner = hash.fetch(from)
      [
        from,
        inner.keys.sort_by(&:to_s).to_h do |to|
          [to, inner.fetch(to)]
        end
      ]
    end
  end

  def metadata_sort_key(metadata)
    metadata.sort_by { |key, _value| key.to_s }
  end
end
