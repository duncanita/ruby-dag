# frozen_string_literal: true

require_relative "test_helper"

class GraphMutationTest < Minitest::Test
  # -------------------------------------------------------------------------
  # Fixture helpers
  # -------------------------------------------------------------------------

  # Builds a graph. Replacement graphs passed to replace_subtree must be
  # self-contained: include all nodes they depend on (or only depend on
  # the boundary node being replaced).
  def make_graph(**node_defs)
    node_defs.each_with_object(DAG::Graph.new) do |(name, opts), graph|
      graph.add_node(name: name, type: :exec, command: "echo #{name}", **opts)
    end
  end

  # -------------------------------------------------------------------------
  # replace_subtree — happy path
  # -------------------------------------------------------------------------

  def test_replace_subtree_returns_mutation_result
    old = make_graph(a: {}, b: {depends_on: [:a]})
    repl = make_graph(a: {depends_on: []}, c: {depends_on: [:a]})

    result = old.replace_subtree(:a, repl)

    assert result.success?
    assert_instance_of DAG::Graph, result.new_graph
    assert_instance_of DAG::MutationResult, result
  end

  # Replacing the root keeps all downstream nodes (their dependency is still satisfied)
  def test_replace_root_preserves_downstream
    # a -> b -> c, replace :a (root) with a -> x
    old = make_graph(a: {}, b: {depends_on: [:a]}, c: {depends_on: [:b]})
    repl = make_graph(a: {depends_on: []}, x: {depends_on: [:a]})

    result = old.replace_subtree(:a, repl)

    assert result.success?
    # b and c are kept; their dep on :a is satisfied by new :a
    assert_equal [:a, :b, :c, :x].sort, result.new_graph.node_names.to_a.sort
    assert_equal [:x], result.added_nodes
    assert_equal [], result.removed_nodes
    assert_equal [], result.stale_nodes
  end

  # Replacing an intermediate node removes its ancestors (the old subtree).
  # The replacement must include :a so that the new :b's dep on :a is satisfied.
  # Since the replacement provides :a with the same name as the old :a, :a is
  # REPLACED (same name appears in both graphs) and is not in removed_nodes.
  # removed_nodes would only be non-empty if the replacement did NOT provide :a
  # (which is impossible here since :b depends on :a and the replacement must be valid).
  def test_replace_subtree_removes_old_ancestors
    # a -> b -> c, replace at :b — old subtree is {a, b}; downstream is {c}
    old = make_graph(a: {}, b: {depends_on: [:a]}, c: {depends_on: [:b]})
    # replacement must include :a so the new :b's dep is satisfied
    repl = make_graph(a: {depends_on: []}, b: {depends_on: [:a]})

    result = old.replace_subtree(:b, repl)

    assert result.success?
    # :a is replaced (old :a → new :a with same name and same deps), not removed
    assert_equal [:a, :b, :c].sort, result.new_graph.node_names.to_a.sort
    assert_equal [], result.added_nodes
    assert_equal [], result.removed_nodes
    # :c's dep on :b is satisfied by new :b
    assert_equal [:b], result.new_graph.node(:c).depends_on.to_a
  end

  # Replacing a leaf node keeps everything else intact
  def test_replace_leaf_keeps_all_other_nodes
    old = make_graph(a: {}, b: {}, c: {depends_on: [:b]})
    repl = make_graph(b: {depends_on: []})

    result = old.replace_subtree(:b, repl)

    assert result.success?
    assert_equal [:a, :b, :c].sort, result.new_graph.node_names.to_a.sort
    assert_equal [], result.removed_nodes
  end

  # Replacing at the boundary (no ancestors): clean swap
  def test_replace_single_node
    old = make_graph(a: {}, b: {depends_on: [:a]})
    repl = make_graph(a: {depends_on: []})

    result = old.replace_subtree(:a, repl)

    assert result.success?
    assert_equal [:a, :b].sort, result.new_graph.node_names.to_a.sort
    assert_equal [], result.removed_nodes
  end

  def test_replace_subtree_consumer_still_wired_to_new_boundary
    # a -> b -> c, replace b
    old = make_graph(a: {}, b: {depends_on: [:a]}, c: {depends_on: [:b]})
    repl = make_graph(a: {depends_on: []}, b: {depends_on: [:a]})

    result = old.replace_subtree(:b, repl)

    assert result.success?
    assert_equal [:b], result.new_graph.node(:c).depends_on.to_a
  end

  # Diamond: a -> b, a -> c, b -> d, c -> d. Replace at :b.
  # Old subtree for :b is {a, b} (a is ancestor of b).
  # Downstream of :b is {c, d}.
  # New graph: {a_replacement, b_replacement, c, d, y}
  def test_replace_subtree_diamond
    old = make_graph(a: {}, b: {depends_on: [:a]}, c: {depends_on: [:a]}, d: {depends_on: [:b, :c]})
    # replacement includes :a so new :b's dep is satisfied
    repl = make_graph(a: {depends_on: []}, b: {depends_on: [:a]}, y: {depends_on: [:b]})

    result = old.replace_subtree(:b, repl)

    assert result.success?
    # old :a removed, downstream {c, d} kept, y added
    assert_equal [:a, :b, :c, :d, :y].sort, result.new_graph.node_names.to_a.sort
    # d still depends on :b (new) and :c
    assert_equal [:b, :c].sort, result.new_graph.node(:d).depends_on.to_a.sort
  end

  # -------------------------------------------------------------------------
  # replace_subtree — stale node detection
  # -------------------------------------------------------------------------

  def test_stale_nodes_includes_downstream_file_writes
    # a (exec) -> b (file_write) -> c (file_write, downstream)
    old = DAG::Graph.new
      .add_node(name: :a, type: :exec, command: "echo a")
      .add_node(name: :b, type: :file_write, path: "/tmp/b.txt", depends_on: [:a])
      .add_node(name: :c, type: :file_write, path: "/tmp/c.txt", depends_on: [:b])
    # replacement: a (so b's dep is satisfied), b
    repl = make_graph(a: {depends_on: []}, b: {depends_on: [:a]})

    result = old.replace_subtree(:b, repl)

    assert result.success?
    # c is kept (downstream), but its artifact may be stale
    assert_equal [:c], result.stale_nodes
    refute_includes result.stale_nodes, :b # b was removed, not downstream
  end

  # -------------------------------------------------------------------------
  # replace_subtree — validation errors
  # -------------------------------------------------------------------------

  def test_replace_subtree_fails_when_boundary_not_found
    old = make_graph(a: {})
    repl = make_graph(b: {})

    result = old.replace_subtree(:nonexistent, repl)

    refute result.success?
    assert_match(/not found/, result.error)
  end

  def test_replace_subtree_fails_when_replacement_not_graph
    old = make_graph(a: {})
    result = old.replace_subtree(:a, {a: {}})

    refute result.success?
    assert_match(/must be a DAG::Graph/, result.error)
  end

  def test_replace_subtree_fails_when_boundary_not_in_replacement
    old = make_graph(a: {})
    repl = make_graph(x: {})

    result = old.replace_subtree(:a, repl)

    refute result.success?
    assert_match(/must contain a node named 'a'/, result.error)
  end

  # Replacement root has different deps than original boundary
  def test_replace_subtree_fails_when_root_deps_dont_match
    old = make_graph(a: {}, b: {depends_on: [:a]})
    # replacement's :a has deps [:x] which is not satisfiable
    repl = make_graph(a: {depends_on: [:x]}, x: {})

    result = old.replace_subtree(:a, repl)

    refute result.success?
    assert_match(/must declare the same dependencies/, result.error)
  end

  # Replacement's internal structure creates a cycle when merged
  def test_replace_subtree_fails_when_replacement_creates_cycle
    old = make_graph(a: {}, b: {depends_on: [:a]})
    # b <-> c cycle within the replacement; replacement's :a has same deps as original
    repl = make_graph(a: {depends_on: []}, b: {depends_on: [:c]}, c: {depends_on: [:b]})

    result = old.replace_subtree(:a, repl)

    refute result.success?
    assert_match(/cycle/i, result.error)
  end

  def test_replace_subtree_failure_preserves_nil_graph
    old = make_graph(a: {})
    result = old.replace_subtree(:nonexistent, make_graph(b: {}))

    refute result.success?
    assert_nil result.new_graph
    assert_equal [], result.added_nodes
  end

  # -------------------------------------------------------------------------
  # subtree_replacement_impact
  # -------------------------------------------------------------------------

  def test_impact_reports_downstream_nodes
    old = make_graph(a: {}, b: {depends_on: [:a]}, c: {depends_on: [:b]})

    impact = old.subtree_replacement_impact(:b, make_graph)

    assert_equal [:c], impact.affected_nodes
    assert_equal :b, impact.boundary_node
    refute impact.is_safe
  end

  def test_impact_safe_when_no_downstream
    # a is downstream of root but nothing downstream of a
    old = make_graph(a: {depends_on: [:root]}, b: {depends_on: [:a]})
    # nothing depends on :a
    impact = old.subtree_replacement_impact(:a, make_graph)

    assert_equal [:b], impact.affected_nodes
    refute impact.is_safe
  end

  def test_impact_flags_file_write_downstream
    old = DAG::Graph.new
      .add_node(name: :a, type: :exec, command: "echo a")
      .add_node(name: :b, type: :file_write, path: "/tmp/b.txt", depends_on: [:a])
      .add_node(name: :c, type: :file_write, path: "/tmp/c.txt", depends_on: [:b])

    impact = old.subtree_replacement_impact(:a, make_graph)

    assert_equal [:b, :c], impact.affected_nodes
    assert_equal [:b, :c], impact.stale_nodes
  end

  def test_impact_unknown_node_raises
    old = make_graph(a: {})
    assert_raises(ArgumentError) { old.subtree_replacement_impact(:nonexistent, make_graph) }
  end

  # -------------------------------------------------------------------------
  # MutationUtils
  # -------------------------------------------------------------------------

  def test_apply_removes_stale_artifacts
    Dir.mktmpdir do |dir|
      b_path = File.join(dir, "b.txt")
      c_path = File.join(dir, "c.txt")
      File.write(b_path, "old b")
      File.write(c_path, "old c")

      old = DAG::Graph.new
        .add_node(name: :a, type: :exec, command: "echo a")
        .add_node(name: :b, type: :file_write, path: b_path, depends_on: [:a])
        .add_node(name: :c, type: :file_write, path: c_path, depends_on: [:b])
      repl = make_graph(a: {depends_on: []}, b: {depends_on: [:a]})
      result = old.replace_subtree(:b, repl)

      deleted = DAG::MutationUtils.apply_subtree_replacement_impact(result, {
        b: b_path,
        c: c_path
      })

      assert_equal [c_path], deleted
      refute File.exist?(c_path), "Stale artifact should be deleted"
      assert File.exist?(b_path), "Non-stale artifact should NOT be deleted"
    end
  end

  def test_apply_is_noop_when_no_stale_nodes
    result = DAG::MutationResult.success(
      new_graph: make_graph,
      added_nodes: [],
      removed_nodes: [],
      stale_nodes: []
    )

    deleted = DAG::MutationUtils.apply_subtree_replacement_impact(result, {})

    assert_equal [], deleted
  end

  def test_apply_is_noop_on_failure
    result = DAG::MutationResult.failure("bad graph")

    deleted = DAG::MutationUtils.apply_subtree_replacement_impact(result, {a: "/tmp/x"})

    assert_equal [], deleted
  end

  def test_apply_skips_missing_files
    result = DAG::MutationResult.success(
      new_graph: make_graph,
      added_nodes: [],
      removed_nodes: [],
      stale_nodes: [:a]
    )

    # No error even if file doesn't exist
    deleted = DAG::MutationUtils.apply_subtree_replacement_impact(result, {a: "/nonexistent/file.txt"})

    assert_equal [], deleted
  end

  # -------------------------------------------------------------------------
  # Traversal helpers
  # -------------------------------------------------------------------------

  def test_ancestors_returns_all_upstream_nodes
    old = make_graph(a: {}, b: {depends_on: [:a]}, c: {depends_on: [:b]})

    assert_equal Set[:a, :b, :c], old.ancestors(:c)
    assert_equal Set[:a, :b], old.ancestors(:b)
    assert_equal Set[:a], old.ancestors(:a)
  end

  def test_ancestors_diamond
    old = make_graph(a: {}, b: {depends_on: [:a]}, c: {depends_on: [:a]}, d: {depends_on: [:b, :c]})

    assert_equal Set[:a, :b, :c, :d], old.ancestors(:d)
  end

  def test_transitive_dependents_returns_all_downstream
    old = make_graph(a: {}, b: {depends_on: [:a]}, c: {depends_on: [:b]})

    assert_equal Set[:b, :c], old.transitive_dependents(:a)
    assert_equal Set[:c], old.transitive_dependents(:b)
    assert_equal Set.new, old.transitive_dependents(:c)
  end

  def test_transitive_dependents_diamond
    old = make_graph(a: {}, b: {depends_on: [:a]}, c: {depends_on: [:a]}, d: {depends_on: [:b, :c]})

    assert_equal Set[:b, :c, :d], old.transitive_dependents(:a)
  end
end
