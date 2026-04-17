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

  def test_workflow_replace_subtree_preserves_unaffected_downstream_inputs
    definition = build_test_workflow(
      source: {
        type: :ruby,
        callable: ->(_input) { DAG::Success.new(value: "payload") }
      },
      config: {
        type: :ruby,
        callable: ->(_input) { DAG::Success.new(value: "v1") }
      },
      process: {
        type: :ruby,
        depends_on: [:source],
        callable: ->(input) { DAG::Success.new(value: input[:source].upcase) }
      },
      report: {
        type: :ruby,
        depends_on: [{from: :process, as: :summary}, :config],
        callable: ->(input) { DAG::Success.new(value: "#{input[:summary]}|#{input[:config]}") }
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
      reconnect: [{from: :summarize, to: :report, metadata: {as: :summary}}]
    )

    result = DAG::Workflow::Runner.new(mutated, parallel: false).call

    assert result.success?
    assert_equal "PAYLOAD-NORMALIZED|v1", result.outputs[:report].value
  end

  def test_workflow_replace_subtree_rejects_duplicate_effective_downstream_aliases
    definition = build_test_workflow(
      source: {
        type: :ruby,
        callable: ->(_input) { DAG::Success.new(value: "payload") }
      },
      config: {
        type: :ruby,
        callable: ->(_input) { DAG::Success.new(value: "v1") }
      },
      process: {
        type: :ruby,
        depends_on: [:source],
        callable: ->(input) { DAG::Success.new(value: input[:source].upcase) }
      },
      report: {
        type: :ruby,
        depends_on: [:process, {from: :config, as: :summary}],
        callable: ->(input) { DAG::Success.new(value: input[:summary]) }
      }
    )

    replacement = build_test_workflow(
      summarize: {
        type: :ruby,
        callable: ->(input) { DAG::Success.new(value: input[:source].upcase) }
      }
    )

    error = assert_raises(ArgumentError) do
      DAG::Workflow.replace_subtree(
        definition,
        root_node: :process,
        replacement: replacement,
        reconnect: [{from: :summarize, to: :report, metadata: {as: :summary}}]
      )
    end

    assert_includes error.message, "duplicate effective downstream alias"
    assert_includes error.message, "report"
    assert_includes error.message, "summary"
  end

  def test_graph_with_subtree_replaced_rejects_unknown_root
    graph = DAG::Graph.new.add_node(:a).freeze
    replacement = DAG::Graph.new.add_node(:b).freeze

    assert_raises(DAG::UnknownNodeError) do
      graph.with_subtree_replaced(root: :missing, replacement_graph: replacement)
    end
  end

  def test_graph_with_subtree_replaced_rejects_non_graph_replacement
    graph = DAG::Graph.new.add_node(:a).freeze

    error = assert_raises(ArgumentError) do
      graph.with_subtree_replaced(root: :a, replacement_graph: Object.new)
    end

    assert_includes error.message, "replacement_graph must be a DAG::Graph"
  end

  def test_graph_with_subtree_replaced_rejects_non_hash_reconnect_descriptor
    graph = DAG::Graph.new
    %i[root down].each { |n| graph.add_node(n) }
    graph.add_edge(:root, :down)
    graph.freeze
    replacement = DAG::Graph.new.add_node(:leaf).freeze

    error = assert_raises(ArgumentError) do
      graph.with_subtree_replaced(
        root: :root,
        replacement_graph: replacement,
        reconnect: [:oops]
      )
    end

    assert_includes error.message, "reconnect entries must be Hashes"
  end

  def test_graph_with_subtree_replaced_rejects_reconnect_without_from
    graph = DAG::Graph.new
    %i[root down].each { |n| graph.add_node(n) }
    graph.add_edge(:root, :down)
    graph.freeze
    replacement = DAG::Graph.new.add_node(:leaf).freeze

    error = assert_raises(ArgumentError) do
      graph.with_subtree_replaced(
        root: :root,
        replacement_graph: replacement,
        reconnect: [{to: :down}]
      )
    end

    assert_includes error.message, "reconnect entries must include :from"
  end

  def test_graph_with_subtree_replaced_rejects_reconnect_without_to
    graph = DAG::Graph.new
    %i[root down].each { |n| graph.add_node(n) }
    graph.add_edge(:root, :down)
    graph.freeze
    replacement = DAG::Graph.new.add_node(:leaf).freeze

    error = assert_raises(ArgumentError) do
      graph.with_subtree_replaced(
        root: :root,
        replacement_graph: replacement,
        reconnect: [{from: :leaf}]
      )
    end

    assert_includes error.message, "reconnect entries must include :to"
  end

  def test_graph_with_subtree_replaced_rejects_reconnect_from_non_replacement_leaf
    graph = DAG::Graph.new
    %i[root down].each { |n| graph.add_node(n) }
    graph.add_edge(:root, :down)
    graph.freeze

    replacement = DAG::Graph.new
    %i[normalize summarize].each { |n| replacement.add_node(n) }
    replacement.add_edge(:normalize, :summarize)
    replacement.freeze

    error = assert_raises(ArgumentError) do
      graph.with_subtree_replaced(
        root: :root,
        replacement_graph: replacement,
        reconnect: [{from: :normalize, to: :down, metadata: {}}]
      )
    end

    assert_includes error.message, "must reference a replacement leaf"
  end

  def test_graph_with_subtree_replaced_rejects_reconnect_to_non_downstream_node
    graph = DAG::Graph.new
    %i[root down sibling].each { |n| graph.add_node(n) }
    graph.add_edge(:root, :down)
    graph.freeze

    replacement = DAG::Graph.new.add_node(:leaf).freeze

    error = assert_raises(ArgumentError) do
      graph.with_subtree_replaced(
        root: :root,
        replacement_graph: replacement,
        reconnect: [{from: :leaf, to: :sibling, metadata: {}}]
      )
    end

    assert_includes error.message, "must reference a downstream node"
  end

  def test_graph_with_subtree_replaced_can_replace_a_root_level_node
    graph = DAG::Graph.new
    %i[root down].each { |n| graph.add_node(n) }
    graph.add_edge(:root, :down, weight: 2)
    graph.freeze

    replacement = DAG::Graph.new
    %i[normalize summarize].each { |n| replacement.add_node(n) }
    replacement.add_edge(:normalize, :summarize)
    replacement.freeze

    result = graph.with_subtree_replaced(
      root: :root,
      replacement_graph: replacement,
      reconnect: [{from: :summarize, to: :down, metadata: {weight: 2}}]
    )

    refute result.node?(:root)
    assert_includes result.roots.to_a, :normalize
    assert result.edge?(:summarize, :down)
    assert_equal({weight: 2}, result.edge_metadata(:summarize, :down))
  end

  def test_graph_with_subtree_replaced_can_replace_a_leaf_node
    graph = DAG::Graph.new
    %i[upstream leaf].each { |n| graph.add_node(n) }
    graph.add_edge(:upstream, :leaf, weight: 9)
    graph.freeze

    replacement = DAG::Graph.new
    %i[normalize summarize].each { |n| replacement.add_node(n) }
    replacement.add_edge(:normalize, :summarize, tag: :inner)
    replacement.freeze

    result = graph.with_subtree_replaced(
      root: :leaf,
      replacement_graph: replacement,
      reconnect: []
    )

    refute result.node?(:leaf)
    assert result.node?(:normalize)
    assert result.node?(:summarize)
    assert_equal({weight: 9}, result.edge_metadata(:upstream, :normalize))
    assert_equal({tag: :inner}, result.edge_metadata(:normalize, :summarize))
  end

  def test_graph_with_subtree_replaced_preserves_replacement_internal_edge_metadata
    graph = DAG::Graph.new
    %i[source root].each { |n| graph.add_node(n) }
    graph.add_edge(:source, :root)
    graph.freeze

    replacement = DAG::Graph.new
    %i[a b].each { |n| replacement.add_node(n) }
    replacement.add_edge(:a, :b, weight: 7, as: :payload)
    replacement.freeze

    result = graph.with_subtree_replaced(
      root: :root,
      replacement_graph: replacement,
      reconnect: []
    )

    assert_equal({weight: 7, as: :payload}, result.edge_metadata(:a, :b))
  end

  def test_graph_with_subtree_replaced_preserves_unrelated_subgraph
    graph = DAG::Graph.new
    %i[source root down other1 other2].each { |n| graph.add_node(n) }
    graph.add_edge(:source, :root)
    graph.add_edge(:root, :down)
    graph.add_edge(:other1, :other2, label: :independent)
    graph.freeze

    replacement = DAG::Graph.new.add_node(:leaf).freeze

    result = graph.with_subtree_replaced(
      root: :root,
      replacement_graph: replacement,
      reconnect: [{from: :leaf, to: :down, metadata: {}}]
    )

    assert result.node?(:other1)
    assert result.node?(:other2)
    assert result.edge?(:other1, :other2)
    assert_equal({label: :independent}, result.edge_metadata(:other1, :other2))
  end

  def test_graph_with_subtree_replaced_preserves_per_predecessor_metadata_on_rewiring
    graph = DAG::Graph.new
    %i[p1 p2 root].each { |n| graph.add_node(n) }
    graph.add_edge(:p1, :root, as: :left)
    graph.add_edge(:p2, :root, as: :right)
    graph.freeze

    replacement = DAG::Graph.new.add_node(:new_root).freeze

    result = graph.with_subtree_replaced(
      root: :root,
      replacement_graph: replacement,
      reconnect: []
    )

    assert_equal({as: :left}, result.edge_metadata(:p1, :new_root))
    assert_equal({as: :right}, result.edge_metadata(:p2, :new_root))
  end

  def test_workflow_replace_subtree_rejects_non_definition_first_arg
    replacement = build_test_workflow(
      x: {type: :ruby, callable: ->(_) { DAG::Success.new(value: :ok) }}
    )

    error = assert_raises(ArgumentError) do
      DAG::Workflow.replace_subtree(Object.new, root_node: :foo, replacement: replacement)
    end

    assert_includes error.message, "definition must be a DAG::Workflow::Definition"
  end

  def test_workflow_replace_subtree_rejects_non_definition_replacement
    definition = build_test_workflow(
      a: {type: :ruby, callable: ->(_) { DAG::Success.new(value: :ok) }}
    )

    error = assert_raises(ArgumentError) do
      DAG::Workflow.replace_subtree(definition, root_node: :a, replacement: Object.new)
    end

    assert_includes error.message, "replacement must be a DAG::Workflow::Definition"
  end

  def test_workflow_replace_subtree_removes_old_step_and_registers_replacement_steps
    definition = build_test_workflow(
      old_root: {type: :ruby, callable: ->(_) { DAG::Success.new(value: :ok) }}
    )

    replacement = build_test_workflow(
      new_a: {type: :ruby, callable: ->(_) { DAG::Success.new(value: :a) }},
      new_b: {
        type: :ruby,
        depends_on: [:new_a],
        callable: ->(_) { DAG::Success.new(value: :b) }
      }
    )

    mutated = DAG::Workflow.replace_subtree(
      definition,
      root_node: :old_root,
      replacement: replacement
    )

    refute mutated.registry.key?(:old_root)
    assert mutated.registry.key?(:new_a)
    assert mutated.registry.key?(:new_b)
  end

  def test_graph_with_subtree_replaced_preserves_original_edge_metadata_when_reconnect_omits_metadata
    graph = DAG::Graph.new
    %i[root down].each { |n| graph.add_node(n) }
    graph.add_edge(:root, :down, as: :summary, weight: 3)
    graph.freeze

    replacement = DAG::Graph.new.add_node(:leaf).freeze

    result = graph.with_subtree_replaced(
      root: :root,
      replacement_graph: replacement,
      reconnect: [{from: :leaf, to: :down}]
    )

    assert_equal({as: :summary, weight: 3}, result.edge_metadata(:leaf, :down))
  end

  def test_graph_with_subtree_replaced_merges_explicit_reconnect_metadata_over_original
    graph = DAG::Graph.new
    %i[root down].each { |n| graph.add_node(n) }
    graph.add_edge(:root, :down, as: :old_alias, weight: 1)
    graph.freeze

    replacement = DAG::Graph.new.add_node(:leaf).freeze

    result = graph.with_subtree_replaced(
      root: :root,
      replacement_graph: replacement,
      reconnect: [{from: :leaf, to: :down, metadata: {as: :new_alias}}]
    )

    assert_equal({as: :new_alias, weight: 1}, result.edge_metadata(:leaf, :down))
  end

  def test_workflow_replace_subtree_preserves_downstream_alias_without_explicit_metadata
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
        depends_on: [{from: :process, as: :summary}],
        callable: ->(input) { DAG::Success.new(value: "report:#{input[:summary]}") }
      }
    )

    replacement = build_test_workflow(
      summary: {
        type: :ruby,
        callable: ->(input) { DAG::Success.new(value: input[:source].upcase) }
      }
    )

    mutated = DAG::Workflow.replace_subtree(
      definition,
      root_node: :process,
      replacement: replacement,
      reconnect: [{from: :summary, to: :report}]
    )

    assert_equal({as: :summary}, mutated.graph.edge_metadata(:summary, :report))

    result = DAG::Workflow::Runner.new(mutated, parallel: false).call
    assert result.success?
    assert_equal "report:PAYLOAD", result.outputs[:report].value
  end

  def test_workflow_replace_subtree_detects_duplicate_alias_with_string_keyed_metadata
    definition = build_test_workflow(
      source: {type: :ruby, callable: ->(_) { DAG::Success.new(value: "payload") }},
      config: {type: :ruby, callable: ->(_) { DAG::Success.new(value: "v1") }},
      process: {
        type: :ruby,
        depends_on: [:source],
        callable: ->(_) { DAG::Success.new(value: "ok") }
      },
      report: {
        type: :ruby,
        depends_on: [:process, {from: :config, as: :summary}],
        callable: ->(input) { DAG::Success.new(value: input[:summary]) }
      }
    )

    replacement = build_test_workflow(
      summarize: {type: :ruby, callable: ->(_) { DAG::Success.new(value: "s") }}
    )

    error = assert_raises(ArgumentError) do
      DAG::Workflow.replace_subtree(
        definition,
        root_node: :process,
        replacement: replacement,
        reconnect: [{from: :summarize, to: :report, metadata: {"as" => :summary}}]
      )
    end

    assert_includes error.message, "duplicate effective downstream alias"
  end

  def test_workflow_replace_subtree_preserves_source_path
    base = build_test_workflow(
      root: {type: :ruby, callable: ->(_) { DAG::Success.new(value: :ok) }}
    )
    definition = base.with(source_path: "/tmp/example.yml")

    replacement = build_test_workflow(
      new_root: {type: :ruby, callable: ->(_) { DAG::Success.new(value: :ok) }}
    )

    mutated = DAG::Workflow.replace_subtree(
      definition,
      root_node: :root,
      replacement: replacement
    )

    assert_equal "/tmp/example.yml", mutated.source_path
  end
end
