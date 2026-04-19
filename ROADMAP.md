# ruby-dag Roadmap

## Overview

ruby-dag is a lightweight, zero-dependency DAG workflow runner in pure Ruby.
Define workflows in YAML or via a Ruby DSL, execute them with automatic
dependency resolution and parallel execution.

## Feature Status

| Feature | Status | Notes |
|---------|--------|-------|
| 1 — YAML + CLI | implemented | `bin/dag`, `Loader` |
| 2 — Parallel execution | implemented | Thread pool, layer-by-layer |
| 3 — FileStore rerun guard | implemented | `ObservedBy` / `Store` |
| 4 — Script args + escaping | implemented | Escaping, safety |
| 5 — Result monad | implemented | `Success` / `Failure` |
| 6 — LLM node type | implemented | `llm` type |
| 7 — Coverage 90%+branch | implemented | 98.64% line / 90.16% branch |
| 8 — Dynamic graph mutation | **implemented** | v1 scope only — see below |
| 9 — Full live graph mutation | future | Not planned for v1 |
| 10 — Self-improving example | implemented | `examples/self-improving.yml` |

## Feature 8 — Dynamic Graph Mutation (v1)

The implemented slice is **immutable subtree replacement between invocations**:

```
impact  = graph.subtree_replacement_impact(:deploy, new_subgraph)
result  = graph.replace_subtree(:deploy, new_subgraph)
deleted = MutationUtils.apply_subtree_replacement_impact(result, artifact_paths)
DAG::Runner.new(result.new_graph).call
```

### What v1 covers

| API | Description |
|-----|-------------|
| `Graph#subtree_replacement_impact` | Preview impact without modifying the graph |
| `Graph#replace_subtree` | Return a new Graph with the subtree swapped out |
| `MutationResult` | Success/failure wrapper with delta and stale-node info |
| `SubtreeImpact` | Impact preview with `affected_nodes`, `stale_nodes`, `is_safe` |
| `MutationUtils.apply_subtree_replacement_impact` | Delete stale artifacts before re-run |
| `Graph#ancestors` | Transitive predecessors of a node |
| `Graph#transitive_dependents` | Transitive successors of a node |

### Replacement graph contract

A replacement graph must:
1. Contain a node with the same name as the boundary being replaced.
2. That node must declare **identical dependencies** to the original boundary.
3. Be **self-contained**: if its nodes depend on each other or on nodes outside
   the replacement, those dependencies must be satisfied within the replacement itself.
4. When merged, the result must be acyclic.

When the replacement is merged, nodes in the replacement **always take
precedence** over any same-name nodes from the original graph (including
downstream nodes). This ensures cycles within the replacement are always
caught by validation.

### What v1 does NOT cover

- Modifying a running graph mid-execution
- Adding nodes to an existing graph (no `add_node` on a live graph)
- Removing nodes without providing a replacement
- Hot-reload of a running workflow

These would require a different architecture (mutable shared state, locks,
coordination) and are out of scope for v1.

### v1 design rationale

The v1 design deliberately restricts mutation to **whole-subtree replacement
between separate Runner invocations**. This keeps the implementation clean,
testable, and safe: no locks, no race conditions, no shared mutable state.
A workflow is built from a graph, run to completion, and if the graph needs
to change, a new graph is built and a new runner is invoked.

## Future / Later Phases

- **Add node to live graph**: `graph.with_added_node(name:, type:, depends_on:)`
- **Remove node from live graph**: `graph.with_removed_node(name:)`
- **Hot-reload**: watch files and rebuild the graph mid-run
- **Transactional rollback**: undo a partially-run mutation on failure

These are not currently planned. If there is real demand they may be
addressed in a future phase.
