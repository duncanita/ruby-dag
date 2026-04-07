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

  # If add_edge raises, the graph state must be byte-identical to before.
  def test_add_edge_is_atomic
    fuzz_iterate do
      graph = build_random_graph
      nodes = graph.each_node.to_a
      next if nodes.empty?

      snapshot_edges = graph.each_edge.to_a.map { |e| [e.from, e.to, e.metadata] }
      from = nodes.sample(random: @rng)
      to = nodes.sample(random: @rng)

      begin
        graph.add_edge(from, to)
      rescue DAG::Error
        assert_equal snapshot_edges, graph.each_edge.to_a.map { |e| [e.from, e.to, e.metadata] }
      end
    end
  end

  # For every edge u→v, u must come strictly before v in topological_sort.
  def test_topological_sort_respects_every_edge
    fuzz_iterate do
      graph = build_random_graph
      position = graph.topological_sort.each_with_index.to_h
      graph.each_edge do |edge|
        assert position[edge.from] < position[edge.to],
          "edge #{edge.from} → #{edge.to} violates topological order"
      end
    end
  end

  def test_topological_layers_match_sort_and_cover_nodes
    fuzz_iterate do
      graph = build_random_graph
      assert_equal graph.topological_sort, graph.topological_layers.flatten
      assert_equal graph.each_node.to_a.sort, graph.topological_sort.sort
    end
  end

  # Differential check against a hand-rolled BFS that doesn't reuse the
  # internal `reachable?` walker shared by `path?` / `descendants`.
  def test_path_agrees_with_descendants_and_naive_bfs
    fuzz_iterate do
      graph = build_random_graph
      nodes = graph.each_node.to_a
      next if nodes.size < 2

      a, b = nodes.sample(2, random: @rng)
      graph_says = graph.path?(a, b)
      assert_equal graph_says, graph.descendants(a).include?(b) || a == b
      assert_equal graph_says, naive_reachable?(graph, a, b)
    end
  end

  def test_descendants_and_ancestors_are_symmetric
    fuzz_iterate do
      graph = build_random_graph
      graph.each_node do |a|
        graph.descendants(a).each do |b|
          assert graph.ancestors(b).include?(a),
            "#{b} ∈ descendants(#{a}) but #{a} ∉ ancestors(#{b})"
        end
      end
    end
  end

  def test_replace_node_preserves_edges
    fuzz_iterate do |i|
      graph = build_random_graph
      nodes = graph.each_node.to_a
      next if nodes.empty?

      old_name = nodes.sample(random: @rng)
      new_name = :"renamed_#{i}"
      next if graph.node?(new_name)

      edge_count = graph.edge_count
      incoming = graph.predecessors(old_name).to_a.sort
      outgoing = graph.successors(old_name).to_a.sort

      graph.replace_node(old_name, new_name)

      refute graph.node?(old_name)
      assert graph.node?(new_name)
      assert_equal edge_count, graph.edge_count
      assert_equal incoming, graph.predecessors(new_name).to_a.sort
      assert_equal outgoing, graph.successors(new_name).to_a.sort
    end
  end

  # Every edge in subgraph(S) has both endpoints in S, and every original
  # edge with both endpoints in S is preserved.
  def test_subgraph_is_closed_and_complete
    fuzz_iterate do
      graph = build_random_graph
      nodes = graph.each_node.to_a
      next if nodes.empty?

      keep = nodes.sample(@rng.rand(1..nodes.size), random: @rng).to_set
      sub = graph.subgraph(keep)

      sub.each_edge do |edge|
        assert keep.include?(edge.from)
        assert keep.include?(edge.to)
      end

      graph.each_edge do |edge|
        next unless keep.include?(edge.from) && keep.include?(edge.to)
        assert sub.edge?(edge.from, edge.to), "subgraph dropped #{edge.from} → #{edge.to}"
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

  def test_structural_equality_is_order_insensitive
    fuzz_iterate do
      a = build_random_graph
      b = DAG::Graph.new
      a.each_node.to_a.shuffle(random: @rng).each { |n| b.add_node(n) }
      a.each_edge.to_a.shuffle(random: @rng).each { |e| b.add_edge(e.from, e.to) }

      assert_equal a, b
      assert_equal a.hash, b.hash
    end
  end

  # freeze.freeze == freeze, and the cached state equals the live state.
  # (Regression: previously crashed with FrozenError on the second call.)
  def test_freeze_is_idempotent
    fuzz_iterate do
      graph = build_random_graph
      twin = graph.dup
      graph.freeze

      assert_same graph, graph.freeze
      assert_equal twin, graph
      assert_equal twin.topological_sort, graph.topological_sort
    end
  end

  def test_remove_then_re_add_edge_round_trips
    fuzz_iterate do
      graph = build_random_graph
      edges = graph.each_edge.select { |e| e.metadata.empty? }
      next if edges.empty?

      edge = edges.sample(random: @rng)
      original = graph.dup
      graph.remove_edge(edge.from, edge.to)
      graph.add_edge(edge.from, edge.to)
      assert_equal original, graph
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
  # sampling.
  def build_random_graph
    graph = DAG::Graph.new
    nodes = (0...@rng.rand(1..MAX_NODES)).map { |i| :"n#{i}" }
    nodes.each { |n| graph.add_node(n) }

    @rng.rand(0..MAX_EDGE_ATTEMPTS).times do
      from = nodes.sample(random: @rng)
      to =
        if @rng.rand < 0.3 && (ancestors = graph.ancestors(from)).any?
          ancestors.to_a.sample(random: @rng)
        else
          nodes.sample(random: @rng)
        end

      begin
        graph.add_edge(from, to)
      rescue DAG::CycleError
        # Expected: cycle attempts and self-edges both raise CycleError.
      end
    end

    graph
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
end
