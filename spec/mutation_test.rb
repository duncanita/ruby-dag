# frozen_string_literal: true

require_relative "test_helper"

class MutationTest < Minitest::Test
  include TestHelpers

  def test_graph_with_subtree_replaced_returns_new_frozen_graph_and_preserves_original
    graph = DAG::Graph.new
    %i[source process report audit].each { |name| graph.add_node(name) }
    graph.add_edge(:source, :process, weight: 5)
    graph.add_edge(:process, :report, as: :payload)
    graph.add_edge(:process, :audit)
    graph.freeze

    replacement = DAG::Graph.new
    %i[normalize summarize].each { |name| replacement.add_node(name) }
    replacement.add_edge(:normalize, :summarize)
    replacement.freeze

    result = graph.with_subtree_replaced(
      root: :process,
      replacement_graph: replacement,
      reconnect: [
        {from: :summarize, to: :report, metadata: {as: :payload}},
        {from: :summarize, to: :audit, metadata: {}}
      ]
    )

    assert result.frozen?
    assert_equal %i[audit normalize report source summarize].sort, result.nodes.to_a.sort
    assert_equal({weight: 5}, result.edge_metadata(:source, :normalize))
    assert_equal({as: :payload}, result.edge_metadata(:summarize, :report))
    assert result.edge?(:summarize, :audit)

    assert graph.node?(:process)
    refute graph.node?(:normalize)
    assert graph.edge?(:process, :report)
  end

  def test_graph_with_subtree_replaced_requires_single_replacement_root
    graph = DAG::Graph.new.add_node(:process).add_node(:report)
    graph.add_edge(:process, :report)
    graph.freeze

    replacement = DAG::Graph.new.add_node(:left).add_node(:right).freeze

    error = assert_raises(ArgumentError) do
      graph.with_subtree_replaced(
        root: :process,
        replacement_graph: replacement,
        reconnect: [{from: :left, to: :report, metadata: {}}]
      )
    end

    assert_includes error.message, "exactly one root"
  end

  def test_workflow_replace_subtree_returns_new_definition_that_runs
    definition = build_test_workflow(
      source: {
        type: :ruby,
        callable: ->(_input) { DAG::Success.new(value: "payload") }
      },
      process: {
        type: :ruby,
        depends_on: [:source],
        callable: ->(input) { DAG::Success.new(value: input[:source].upcase) }
      },
      report: {
        type: :ruby,
        depends_on: [:process],
        callable: ->(input) { DAG::Success.new(value: "report:#{input[:summarize]}") }
      }
    )

    replacement = build_test_workflow(
      normalize: {
        type: :ruby,
        callable: ->(input) { DAG::Success.new(value: "#{input[:source]}-normalized") }
      },
      summarize: {
        type: :ruby,
        depends_on: [:normalize],
        callable: ->(input) { DAG::Success.new(value: input[:normalize].upcase) }
      }
    )

    mutated = DAG::Workflow.replace_subtree(
      definition,
      root_node: :process,
      replacement: replacement,
      reconnect: [{from: :summarize, to: :report, metadata: {as: :summarize}}]
    )

    result = DAG::Workflow::Runner.new(mutated, parallel: false).call

    assert result.success?
    assert_equal "PAYLOAD-NORMALIZED", result.outputs[:summarize].value
    assert_equal "report:PAYLOAD-NORMALIZED", result.outputs[:report].value

    assert definition.graph.node?(:process)
    refute definition.graph.node?(:normalize)
  end
end
