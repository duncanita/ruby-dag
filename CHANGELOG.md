# Changelog

## Unreleased

### Added

- R0 foundation files: `require "ruby-dag"` entrypoint, boundary port
  contracts, immutable tagged types, JSON-safety helpers, custom DAG cops,
  `CONTRACT.md`, and CI scaffolding for Ruby 3.4/head.

## 0.4.0

### Added

- **Declarative `run_if` DSL** for YAML workflows. Conditions use logical
  operators (`all`, `any`, `not`) and leaf predicates on direct dependencies
  (`from`, `status`, `value` with `equals`/`in`/`present`/`nil`/`matches`).
  Callable `run_if` continues to work for programmatic workflows.
- `Condition` module: normalize, validate, evaluate, dump, rename_from.
- `Validator` module: checks `run_if` conditions against graph structure.
- `Graph#each_successor`: zero-alloc iteration over successors, symmetric
  with `each_predecessor`.
- `Definition#replace_step` rewrites declarative `run_if` `:from` references
  when renaming nodes.
- `Loader` rejects blank `run_if:` (null/empty) instead of silently treating
  it as "no condition".
- `Condition.normalize` rejects non-YAML-safe values in `equals`/`in`
  predicates and malformed operands (nil/callable) inside logical operators.

### Fixed

- **Sub_workflow paused/waiting silently dropped downstream nodes**
  (issue #75). When a sub_workflow returned `:paused` or `:waiting`,
  `TaskCompletionHandler` skipped writing both `results[name]` and
  `statuses[name]`. The next layer's `LayerAdmitter#dependency_outputs_ready?`
  then quietly `next`'d any descendant whose dependency was missing — no
  trace entry, no error. Fixed by:
  - `TaskCompletionHandler` now writes `statuses[name]` (`:waiting` /
    `:paused`) and persists the node state on lifecycle outcomes.
  - `LayerAdmitter` uses a tri-state `predecessor_admission_status`
    predicate. Predecessors in `:waiting`, `:paused`, or `:blocked_upstream`
    block downstream admission and emit a `BlockedResult` that the
    `TraceRecorder` materializes as a `:blocked_upstream` `TraceEntry`.
  - `:blocked_upstream` propagates transitively through `statuses`, so
    chains and diamond joins are recorded explicitly without
    interrupting independent parallel branches.
  - The same status-aware admission also closes the analogous
    silent-drop for `SchedulePolicy.waiting?` and
    `DependencyInputResolver::WaitingForDependencyError`.
  - New `ExecutionPersistence#persist_paused_node` mirrors
    `persist_waiting_node` for paused lifecycle outcomes.
- **EINTR in `Steps::Exec#drain_pipes`**: `read_nonblock(exception: false)`
  does not suppress `Errno::EINTR`. Under the `Threads` strategy with
  concurrent `:exec` steps, SIGCHLD from a sibling child could crash a
  healthy step. Now rescued with retry, matching the existing fix in
  `Parallel::Processes`.
- **`empty_child_payload` diagnostics**: the error now includes the child's
  exit status ("killed by signal 9", "exited 1") instead of the opaque
  "exited without writing a payload".
- `run_if` is canonicalized once at `Step` construction. Ruby entry points
  (`Step.new`, `Loader.from_hash`) treat `run_if: nil` as omitted, while YAML
  keeps rejecting blank `run_if:`.
- `Condition.evaluate` handles callable conditions instead of crashing with
  `NoMethodError`.

### Documentation

- FileRead/FileWrite document their path policy: no sandboxing, caller
  responsible for validation with untrusted definitions.
- README documents the declarative `run_if` DSL, condition combinators,
  and `workflow_dead_end` failure mode.

## 0.3.1

- Removed Ractors strategy (Ruby 4.0 deadlock detector incompatibility).
- Consolidated `KILL_GRACE_SECONDS` as single source of truth.
- 100% line and branch coverage enforcement.
