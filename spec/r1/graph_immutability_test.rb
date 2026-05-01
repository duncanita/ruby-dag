# frozen_string_literal: true

require_relative "../test_helper"

class GraphImmutabilityTest < Minitest::Test
  def test_frozen_topological_layers_are_deep_frozen
    graph = DAG::Graph.new
      .add_node(:a)
      .add_node(:b)
      .add_edge(:a, :b)
      .freeze

    layers = graph.topological_layers

    assert layers.frozen?
    assert layers.all?(&:frozen?)
    assert_raises(FrozenError) { layers.first << :x }
    assert_equal [[:a], [:b]], graph.topological_layers
  end
end
