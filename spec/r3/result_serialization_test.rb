# frozen_string_literal: true

require_relative "../test_helper"

# Full-fidelity serialization seam for step outcomes: every sibling type
# (Success / Failure / Waiting) projects through `to_h` and reconstructs
# through `Result.from_h`, including after a JSON round-trip through the
# stdlib serializer (Symbol keys become Strings).
class R3ResultSerializationTest < Minitest::Test
  def test_success_round_trips_with_mutations_and_effects
    graph = DAG::Graph.new
    graph.add_node(:x)
    graph.add_node(:y)
    graph.add_edge(:x, :y, weight: 2)
    replacement = DAG::ReplacementGraph[
      graph: graph,
      entry_node_ids: [:x],
      exit_node_ids: [:y]
    ]
    success = DAG::Success[
      value: {"answer" => 42},
      context_patch: {"k" => "v"},
      proposed_mutations: [
        DAG::ProposedMutation[
          kind: :replace_subtree,
          target_node_id: :a,
          replacement_graph: replacement,
          rationale: "because",
          confidence: 0.5,
          metadata: {"m" => 1}
        ]
      ],
      proposed_effects: [
        DAG::Effects::Intent[type: "mail", key: "m-1", payload: {"to" => "ops"}, metadata: {"x" => 1}]
      ],
      metadata: {"meta" => true}
    ]

    restored = DAG::Result.from_h(success.to_h)
    assert_equal success, restored

    json_restored = DAG::Result.from_h(json_round_trip(success.to_h))
    assert_equal success.value, json_restored.value
    assert_equal success.context_patch, json_restored.context_patch
    assert_equal success.metadata, json_restored.metadata
    assert_equal success.proposed_effects, json_restored.proposed_effects

    restored_mutation = json_restored.proposed_mutations.first
    assert_equal :replace_subtree, restored_mutation.kind
    assert_equal :a, restored_mutation.target_node_id
    assert_equal graph.to_h, restored_mutation.replacement_graph.graph.to_h
    assert_equal %w[x y], restored_mutation.replacement_graph.entry_node_ids.map(&:to_s) +
      restored_mutation.replacement_graph.exit_node_ids.map(&:to_s)
  end

  def test_failure_round_trips_retriable_flag
    failure = DAG::Failure[error: {"code" => "step_raised"}, retriable: true, metadata: {"m" => 1}]

    restored = DAG::Result.from_h(json_round_trip(failure.to_h))
    assert_equal failure, restored
    assert restored.retriable
  end

  def test_waiting_round_trips_through_result_from_h
    waiting = DAG::Waiting[
      reason: :external_call,
      resume_token: "tok-1",
      not_before_ms: 5_000,
      proposed_effects: [DAG::Effects::Intent[type: "call", key: "c-1", payload: {"n" => 1}]],
      metadata: {"m" => 2}
    ]

    restored = DAG::Result.from_h(json_round_trip(waiting.to_h))
    assert_equal waiting, restored
  end

  def test_from_h_rejects_unknown_or_missing_status
    assert_raises(ArgumentError) { DAG::Result.from_h({status: "nope"}) }
    assert_raises(ArgumentError) { DAG::Result.from_h({}) }
    assert_raises(ArgumentError) { DAG::Result.from_h(:not_a_hash) }
  end

  def test_graph_from_h_restores_nodes_edges_and_metadata
    graph = DAG::Graph.new
    graph.add_node(:a)
    graph.add_node(:b)
    graph.add_node(:c)
    graph.add_edge(:a, :b, kind: "data")
    graph.add_edge(:b, :c)
    graph.freeze

    restored = DAG::Graph.from_h(json_round_trip(graph.to_h))
    assert restored.frozen?
    assert_equal graph.to_h, restored.to_h
  end

  private

  def json_round_trip(hash)
    JSON.parse(JSON.generate(hash))
  end
end
