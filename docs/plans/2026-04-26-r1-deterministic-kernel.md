# R1 — Deterministic core runner and default adapters

Issue: #71 (parent: #69). Branch lives off the current feature branch
`fix/issue-94-sub-workflow-leaf-missing` for now; will rebase onto `main`
before opening the PR.

## Goal

Land the new deterministic kernel from Roadmap v3.4 R1 alongside the legacy
`DAG::Workflow::Runner` stack, without touching legacy callers. The new
kernel uses the R0 ports, tagged types, errors, and cops landed in #70.

## Scope decision: total replacement

User confirmed 2026-04-26: "sostituisci tutto, non siamo ancora in
produzione". R1 takes over the canonical paths. The legacy workflow
runtime is deleted in this same PR.

Files **kept** (R0 surface + Graph core):

- `lib/ruby-dag.rb`, `lib/dag.rb` (rewritten require list), `lib/dag/version.rb`
- `lib/dag/errors.rb`, `lib/dag/immutability.rb`, `lib/dag/edge.rb`
- `lib/dag/graph.rb` (extended in Stage A), `lib/dag/graph/{builder,validator}.rb`
- `lib/dag/result.rb`, `lib/dag/success.rb`, `lib/dag/failure.rb`
- `lib/dag/types.rb` and the per-type files: `step_input.rb`, `waiting.rb`,
  `replacement_graph.rb`, `proposed_mutation.rb`, `runtime_profile.rb`,
  `run_result.rb`, `event.rb`
- `lib/dag/ports/*.rb`
- `spec/r0/*`, `spec/test_helper.rb` (rewritten)
- Specs for kept code: `graph_test.rb`, `graph_builder_test.rb`,
  `graph_validator_test.rb`, `graph_fuzz_test.rb`, `result_test.rb`,
  `errors_test.rb`, `run_result_test.rb`, `clock_test.rb`

Files **deleted**:

- entire `lib/dag/workflow/` (legacy Definition, Loader, Dumper, Runner,
  parallel strategies, registry, condition DSL, validators, middleware,
  scheduling, execution_*, layer_*, sub_workflow, mutation,
  invalidation, attempt_trace, etc.)
- `lib/dag/workflow.rb` (legacy module shell)
- `bin/dag` (legacy YAML CLI, redo at Release phase)
- `examples/*.{rb,yml}` and `examples/sub_workflows/` (all wired to
  legacy runner)
- `script/{benchmark,soak}.rb` (legacy benchmarks, redo against R1
  later)
- `benchmarks/*.md` (results obsolete)
- ~35 legacy specs (everything in `spec/` not listed under "kept")

Files **added** at the canonical roadmap paths:

| Path                                          |
| --------------------------------------------- |
| `lib/dag/workflow/definition.rb`              |
| `lib/dag/execution_context.rb`                |
| `lib/dag/step_protocol.rb`                    |
| `lib/dag/step/base.rb`                        |
| `lib/dag/runner.rb`                           |
| `lib/dag/step_type_registry.rb`               |
| `lib/dag/builtin_steps/{noop,passthrough}.rb` |
| `lib/dag/adapters/**`                         |
| `spec/support/*`                              |
| `spec/r1/*`                                   |

## Stages

### Stage A — Graph deterministic helpers (additive)

Touch `lib/dag/graph.rb` only. Add (no removals, no rename):

- `descendants_of(root_id, include_self: true)` — Set
- `exclusive_descendants_of(root_id, include_self: true)` — Set of nodes
  reachable only through `root_id`
- `shared_descendants_of(root_id)` — Set of descendants of `root_id`
  with at least one ancestor outside `descendants_of(root_id)`
- `to_h` — canonical hash for fingerprint
  (`{ nodes: [...], edges: [[from, to, metadata], ...], payloads: {...} }`,
  symbol keys, sorted by `id.to_s`)
- `topological_order` — alias of an ASCII-sorted-tie-break Kahn's pass
  built from existing `topological_sort` plus a deterministic comparator;
  add a kernel-local helper, do not break existing `topological_layers` /
  `topological_sort` semantics.

The existing `add_node`/`add_edge` mutating API stays. R1's chainable
immutable surface is provided by `Kernel::Definition` (Stage B), not by
`Graph` itself, so the kernel never mutates a `Graph` instance after
construction.

Tests: extend `spec/graph_test.rb` with the new methods and a fixture
covering exclusive vs shared descendants.

### Stage B — Kernel::Definition + ExecutionContext

`lib/dag/kernel/definition.rb`:

- `DAG::Kernel::Definition` is a frozen value built by chained
  `.add_node(id, type:, config: {})` and `.add_edge(from, to)` returning
  new instances each time (copy-on-write internal hash + frozen Graph
  rebuild on each call is fine for R1 sizes).
- `#revision` starts at `1`. Mutation service in R3 will append
  revisions, not R1.
- `#fingerprint(via:)` calls `via.compute(to_h)`.
- `#to_h` returns canonical hash including `revision`, `nodes`, `edges`,
  `step_types` (per-node `{type:, config:}` deep-frozen).
- No mutable memoization: every accessor recomputes or uses an ivar set
  in `initialize` then frozen.
- `#has_node?(id)` and `#step_type_for(id)`.

`lib/dag/execution_context.rb`:

- `DAG::ExecutionContext` wraps a deep-frozen Hash with copy-on-write
  semantics.
- `.from(hash)` factory: deep-dup, deep-freeze, JSON-safety check.
- `#merge(patch)` returns a new context with patch applied (deep-dup
  patch first, deep-freeze the merged hash).
- `#fetch(key, default = sentinel)`, `#dig(*keys)`.
- `#to_h` returns a fresh deep-dup, never the internal frozen hash.
- `#==`, `#hash` based on canonical hash content.

Tests:
- `spec/r1/execution_context_test.rb` (CoW, deep-frozen, JSON safety,
  to_h is a dup).
- `spec/r1/kernel_definition_test.rb` (chaining returns new instances,
  revision: 1, fingerprint stable, to_h canonical, cycle raises
  `CycleError` carrying offending edge in message).

### Stage C — Step protocol + registry + builtins

- `lib/dag/step_protocol.rb` — module documenting the contract; mostly
  a doc + a class method `DAG::StepProtocol.implements?(klass)` that
  asserts `respond_to?(:call)` with arity 1.
- `lib/dag/step/base.rb` — `DAG::Step::Base`: `initialize(config: {})`
  deep-dups + deep-freezes, then `freeze`s self. Subclasses override
  `#call(input)`.
- `lib/dag/step_type_registry.rb` — `DAG::StepTypeRegistry`:
  - `#register(name:, klass:, fingerprint_payload:, config: {})`
  - identical fingerprint => no-op; different fingerprint =>
    `FingerprintMismatchError`
  - `#lookup(name)` => `UnknownStepTypeError` if missing
  - `#freeze!` freezes the internal hash and self
- `lib/dag/builtin_steps/noop.rb`:
  `Success[value: nil, context_patch: {}]`.
- `lib/dag/builtin_steps/passthrough.rb`:
  `Success[value: input.context, context_patch: input.context.to_h]`.

Tests: `spec/r1/step_type_registry_test.rb`, `spec/r1/builtin_steps_test.rb`.

### Stage D — Default adapters

- `lib/dag/adapters/stdlib/clock.rb` — wall + monotonic ms.
- `lib/dag/adapters/stdlib/id_generator.rb` — `SecureRandom.uuid`.
- `lib/dag/adapters/stdlib/fingerprint.rb` — JSON-canonical SHA256
  (already in roadmap appendix).
- `lib/dag/adapters/stdlib/serializer.rb` — JSON wrapper (`dump`/`load`
  enforcing `DAG.json_safe!`).
- `lib/dag/adapters/null/event_bus.rb` — drop, frozen.
- `lib/dag/adapters/memory/event_bus.rb` — append + subscribe; events
  reader returns deep-frozen deep-dup; no Thread/Mutex/Queue.
- `lib/dag/adapters/memory/storage.rb` — single-process stateful Hash;
  internals in `DAG::Adapters::Memory::StorageState` module so the in-
  place mutation cop can scope-allow it. Implements every method on
  `Ports::Storage`: workflow CAS, revisions, node states, attempts,
  events, with `StaleStateError` / `StaleRevisionError` /
  `UnknownWorkflowError` raised at the appropriate layers. Returns
  deep-frozen deep-dup snapshots.

Cop allowance: extend `Dag/NoInPlaceMutation` to skip
`lib/dag/adapters/memory/**` (the cop already supports per-path scoping
via the rubocop AllowedPatterns mechanism — verify).

Tests:
- `spec/r1/stdlib_adapters_test.rb` (clock monotonicity sane,
  id_generator returns 36-char UUIDs, fingerprint deterministic and
  collision-resistant on key reorder, serializer rejects non-json-safe).
- `spec/r1/null_event_bus_test.rb`.
- `spec/r1/memory_event_bus_test.rb`.
- `spec/r1/memory_storage_cas_test.rb` — workflow + node CAS rejection,
  attempt counting, event seq monotonic.

### Stage E — Runner kernel

`lib/dag/runner.rb`:

- `initialize(storage:, event_bus:, registry:, clock:, id_generator:,
  fingerprint:, serializer:)` — every keyword required, raises
  `ArgumentError` if any is missing or nil. Freezes self.
- `#call(workflow_id)` implements the bound algorithm in the roadmap:
  CAS pending|waiting|paused → running, optional first-run
  `workflow_started`, layered loop with eligibility = predecessors all
  committed and node `:pending`, ordered by topological_order.
- For each eligible node: count attempts, `begin_attempt`, build
  `StepInput[context: effective_context(node), node_id:,
  attempt_number:, metadata: {revision:, fingerprint:}]`, call step
  through `safe_call_step` (rescues StandardError → `Failure[error:
  {class:, message:}, retriable: false]`; never catches `NoMemoryError /
  SystemExit / Interrupt`).
- Outcomes:
  - `Success` → commit attempt + node, append `node_committed`. If
    `proposed_mutations.any?` → workflow `running` → `paused` and emit
    `workflow_paused`; return RunResult `:paused`.
  - `Waiting` → commit attempt as waiting + node `:waiting` + emit
    `node_waiting`.
  - `Failure` → if retriable && `attempt_number <
    runtime_profile.max_attempts_per_node`: commit attempt failed, node
    stays `:pending`. Otherwise commit attempt failed, node `:failed`,
    workflow `running` → `failed`, emit `workflow_failed`, break.
- After the loop: if all nodes committed → `:completed`, elif any
  waiting → `:waiting`, elif any failed → `:failed`, else `:failed`
  with diagnostic.
- `#retry_workflow(workflow_id)` — only valid when workflow `:failed` and
  `workflow_retry_count < max_workflow_retries`. Resets `:failed` nodes
  to `:pending`, increments `workflow_retry_count`, emits no event by
  itself (next `#call` does). Raises `WorkflowRetryExhaustedError` when
  the budget is spent.
- Effective context calculation: load committed predecessor attempts in
  topological_order restricted to predecessors with ASCII tie-break,
  apply `context_patch` deep-CoW; later predecessor wins on key
  collision. Bit-identical reproducibility verified by fingerprinting
  the resulting hash and asserting equality across 100 runs.
- No `Thread`, no `Mutex`, no `Queue`, no `Ractor` anywhere.

Tests: covered in Stage F.

### Stage F — R1 spec suites + helpers

Helpers under `spec/support/`:
- `runner_factory.rb`
- `workflow_builders.rb`
- `step_helpers.rb`

Specs under `spec/r1/`:
- `linear_workflow_test.rb` (DoD: A→B→C with `:passthrough` + initial
  context propagated).
- `fan_out_fan_in_test.rb` (DoD: A→{B,C}→D, deterministic order, both
  branches finish before D).
- `cycle_detection_test.rb` (DoD: A→B→A raises `CycleError` containing
  the offending edge string).
- `context_merge_order_test.rb` (DoD: 100 independent runs produce
  identical context fingerprints).
- `memory_storage_cas_test.rb` (already listed in Stage D; also covers
  the workflow CAS DoD).
- `runner_signature_test.rb` (DoD: missing keyword raises
  `ArgumentError`; `Runner` frozen).
- `many_workflows_single_process_test.rb` (DoD: 100 independent
  workflows complete cleanly).
- `retry_node_test.rb` (DoD: retriable node fails twice, succeeds on
  third with `max_attempts_per_node: 3`; same setup but failing 3
  times → workflow `:failed`).
- `retry_workflow_test.rb` (DoD: `retry_workflow` resets failed nodes
  on a workflow with budget left; raises
  `WorkflowRetryExhaustedError` when exhausted).

`test_helper.rb` includes `RunnerFactory`, `WorkflowBuilders`,
`StepHelpers` in `Minitest::Test`.

### Stage G — Wiring & docs

- `lib/dag.rb`: append `require_relative` lines for the new files.
- `CHANGELOG.md`: R1 entry under Unreleased.
- `ROADMAP.md`: mark R1 mandatory outputs landed.
- `CONTRACT.md`: no changes (R1 is pure implementation; the contract
  was already finalized in R0).

### Stage H — Verification

- `bundle exec rake test` (existing legacy + new R1 specs both green).
- `bundle exec standardrb` clean.
- `bundle exec rubocop` clean (custom cops happy with the new files).
- Manual smoke: run `examples/`-style scenario through the new
  `DAG::Runner` to confirm event ordering and CAS behavior.

## Out of scope (deferred to later phases)

- Removing legacy `Workflow::Runner` / `Loader` / `Dumper` / parallel
  strategies — Release phase (#74).
- `:branch` builtin step — explicitly punted by the roadmap until edge
  metadata is ready in R3.
- SQLite storage — phase S0 (`ruby-dag-sqlite` repo).
- Resume / crash recovery semantics for `Memory::Storage` — R2 (#72).
- Mutation service apply — R3 (#73).

## Risks

1. **Cop interaction with `Memory::Storage`**: the `NoInPlaceMutation`
   cop forbids in-place hash writes in `lib/dag/**`. Confirm the cop's
   ignored-path config supports a per-file allowance; otherwise the
   cop needs a one-line update. Estimated 10 minutes if it doesn't.
2. **Effective-context determinism**: relies on a topological order
   restricted to predecessors with `id.to_s` ASCII tie-break. The
   existing `Graph#topological_sort` is deterministic but uses Kahn
   over a hash whose insertion order tracks `add_node`. Need to verify
   ties are broken by string compare when several nodes share the same
   in-degree at the same level. If not, add a Stage A helper that
   explicitly sorts the per-level frontier.
3. **Frozen Runner + injected mutables**: `Memory::Storage` and
   `Memory::EventBus` are mutable internally. The Runner being frozen
   doesn't protect them. Spec-document that `Runner` is reentrant only
   per workflow_id, never concurrently across the same store/bus pair.

## Estimate

- Stages A–G ≈ 12–16 hours of focused work.
- Spec count ≈ 9 new files, ~200–250 assertions total.
- Net new LoC ≈ 1500 in `lib/`, ≈ 800 in `spec/`.

One PR, branch off `main`. The R1 acceptance gate is `rake test +
rubocop` clean plus all 11 DoD bullets covered by spec assertions.
