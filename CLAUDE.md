# CLAUDE.md

## What this is

Ruby PORO DAG library targeting Roadmap v3.4. The kernel is the deterministic
runtime sketched in `Ruby DAG Project Roadmap v3.4.md`: an immutable workflow
definition runs through `DAG::Runner` against injected ports for storage,
event bus, clock, ids, fingerprint, and serialization. Zero runtime
dependencies; Ruby 3.4+.

## Commands

```bash
bundle exec rake          # test + standardrb (the actual gate)
bundle exec rake test     # tests only
bundle exec rubocop       # custom DAG cops (NoThreadOrRactor, NoMutableAccessors,
                          # NoInPlaceMutation, NoExternalRequires)
```

## Architecture

Two layers, in order of dependency:

- **Graph** (`lib/dag/graph.rb`) — pure DAG. Nodes are Symbols, edges are
  `Edge = Data.define(:from, :to, :metadata)`. Acyclicity is enforced on every
  `add_edge` via an O(V+E) reachability walk. `each_node` and `each_edge` are
  the ONLY iteration entry points (no `Enumerable` mixin). Frozen graphs
  eagerly cache layers, sort, roots, leaves, and edges. Topological sort is
  deterministic with `id.to_s` ASCII tie-break at every Kahn frontier.
  R1-specific helpers: `descendants_of`, `exclusive_descendants_of`,
  `shared_descendants_of`, `topological_order`, canonical sorted `to_h`.
- **Kernel runtime** (R1) — built on top of Graph, ports, and tagged types:
  - `DAG::Workflow::Definition` — immutable, chainable. `add_node(id, type:,
    config: {})` and `add_edge(from, to, **meta)` return new frozen instances.
    `revision` starts at 1; `fingerprint(via: port)` defers to
    `Ports::Fingerprint`.
  - `DAG::ExecutionContext` — deep-frozen copy-on-write hash wrapper.
    `merge` returns a new context; `to_h` returns a fresh deep-dup.
  - `DAG::Step::Base` + `DAG::StepProtocol` — steps return
    `Success | Waiting | Failure`. Subclasses freeze themselves at
    construction.
  - `DAG::StepTypeRegistry` — `register(name:, klass:, fingerprint_payload:,
    config: {})`. Re-registering the same name with a different payload
    raises `FingerprintMismatchError`. `freeze!` after registration is
    complete; lookup of an unknown type raises `UnknownStepTypeError`.
  - Built-ins: `DAG::BuiltinSteps::{Noop, Passthrough}`. `:branch` is
    deferred to a later phase.
  - `DAG::Runner` — frozen kernel. `#call(workflow_id)` runs the layered
    algorithm; `#retry_workflow(workflow_id)` enforces
    `max_workflow_retries` and raises `WorkflowRetryExhaustedError` when
    the budget is spent.

## Key files

```
lib/dag.rb                                # require entry point (no I/O)
lib/dag/version.rb                        # DAG::VERSION
lib/dag/errors.rb                         # Exception hierarchy (DAG::Error base)
lib/dag/edge.rb                           # Edge = Data.define(:from, :to, :metadata)
lib/dag/graph.rb                          # Graph class
lib/dag/graph/builder.rb                  # Builder.build { |b| ... } -> frozen Graph
lib/dag/graph/validator.rb                # Structural validation -> Validator::Report
lib/dag/result.rb                         # DAG::Result marker + Result.try / assert_result!
lib/dag/success.rb                        # Success(value:, context_patch:, proposed_mutations:, metadata:)
lib/dag/failure.rb                        # Failure(error:, retriable:, metadata:)
lib/dag/types.rb                          # Loads tagged types
lib/dag/step_input.rb                     # StepInput[context:, node_id:, attempt_number:, metadata:]
lib/dag/waiting.rb                        # Waiting[reason:, resume_token:, not_before_ms:, metadata:]
lib/dag/proposed_mutation.rb              # ProposedMutation[kind:, target_node_id:, replacement_graph:, ...]
lib/dag/replacement_graph.rb              # ReplacementGraph[graph:, entry_node_ids:, exit_node_ids:]
lib/dag/runtime_profile.rb                # RuntimeProfile[durability:, max_attempts_per_node:, max_workflow_retries:, event_bus_kind:, metadata:]
lib/dag/run_result.rb                     # RunResult(state:, last_event_seq:, outcome:, metadata:)
lib/dag/event.rb                          # Event[seq:, type:, workflow_id:, revision:, ...]; TYPES is closed
lib/dag/immutability.rb                   # deep_freeze, deep_dup, json_safe!
lib/dag/ports/storage.rb                  # Ports::Storage interface
lib/dag/ports/event_bus.rb                # Ports::EventBus interface
lib/dag/ports/fingerprint.rb              # Ports::Fingerprint interface
lib/dag/ports/clock.rb                    # Ports::Clock interface
lib/dag/ports/id_generator.rb             # Ports::IdGenerator interface
lib/dag/ports/serializer.rb               # Ports::Serializer interface
lib/dag/execution_context.rb              # DAG::ExecutionContext (deep-frozen CoW)
lib/dag/step_protocol.rb                  # DAG::StepProtocol.valid_result? (boundary type guard)
lib/dag/step/base.rb                      # DAG::Step::Base (freezes self + config)
lib/dag/step_type_registry.rb             # DAG::StepTypeRegistry
lib/dag/builtin_steps/noop.rb             # :noop -> Success(nil, {})
lib/dag/builtin_steps/passthrough.rb      # :passthrough -> Success(context, context)
lib/dag/workflow/definition.rb            # DAG::Workflow::Definition (immutable, chainable)
lib/dag/runner.rb                         # DAG::Runner kernel + private RunContext carrier
lib/dag/adapters/stdlib/clock.rb          # wall + monotonic ms
lib/dag/adapters/stdlib/id_generator.rb   # SecureRandom.uuid
lib/dag/adapters/stdlib/fingerprint.rb    # JSON-canonical SHA256
lib/dag/adapters/stdlib/serializer.rb     # JSON wrapper enforcing json_safe!
lib/dag/adapters/null/event_bus.rb        # drops everything; optional logger
lib/dag/adapters/memory/event_bus.rb      # bounded ring buffer + subscribers
lib/dag/adapters/memory/storage.rb        # facade; deep-dup-freezes returns
lib/dag/adapters/memory/storage_state.rb  # mutable bookkeeping (only spot in lib/dag/** allowed to mutate)
```

Tests live in `spec/r0/` (R0 invariants) and `spec/r1/` (R1 DoD). Shared
helpers under `spec/support/{runner_factory,workflow_builders,step_helpers}.rb`
are auto-included into `Minitest::Test` by `spec/test_helper.rb`.

## Error hierarchy

All errors inherit from `DAG::Error < StandardError`:

- `CycleError` — adding edge would create a cycle (message names the
  offending edge)
- `DuplicateNodeError`, `UnknownNodeError`
- `ValidationError` (has `.errors` array), `SerializationError`
- `PortNotImplementedError`
- `StaleStateError`, `StaleRevisionError`, `ConcurrentMutationError`
- `FingerprintMismatchError`
- `UnknownStepTypeError`, `UnknownWorkflowError`
- `WorkflowRetryExhaustedError`

Adding a duplicate edge is **not** an error — `add_edge` is idempotent.

## File-per-class convention

One class, module, or `Data.define` per file is the project default — it
makes navigation predictable: a name `Foo::Bar` lives at
`lib/dag/foo/bar.rb`, no exceptions to remember.

The single exception: **private internal data carriers stay inline in
their consumer's file.** A `Data.define` that exists only to suppress
parameter sprawl inside one other class, that is never imported
elsewhere, that has no validation logic, and that would be deleted if
its consumer were deleted, lives at the top of the consumer's file. The
test for inlining is: *"if I delete the consumer, does this carrier die
with it?"* If yes, inline. If no (it's reusable, public, validated,
exposed in `CONTRACT.md`), give it a file.

This keeps the convention's value (predictable navigation for the
public surface) without paying ceremony for private scaffolding.

## R1 conventions

- Tests use Minitest in `spec/`, named `*_test.rb`. Helpers in
  `spec/support/` are auto-included.
- All graph nodes are symbols internally (`.to_sym` on input).
- Step inputs flow through `DAG::StepInput[context: ec, node_id:,
  attempt_number:, metadata: {workflow_id:, revision:}]` where `ec` is an
  `ExecutionContext`. `input.context` is always an `ExecutionContext`.
- Effective context for a node = `initial_context` + each predecessor's
  committed-attempt `context_patch`, applied in `id.to_s` ASCII order
  over predecessors. Later predecessor wins on key collision. Bit-identical
  across runs (verified by 100-run fingerprint stability test).
- Steps return one of `Success | Waiting | Failure`. Anything else is
  caught at the Runner boundary as
  `Failure[error: {code: :step_bad_return, ...}, retriable: false]`.
- `StandardError` raised in `#call` is converted to
  `Failure[error: {code: :step_raised, class:, message:}, retriable: false]`.
  `NoMemoryError`, `SystemExit`, and `Interrupt` propagate.
- `count_attempts` excludes `:aborted` attempts. `Runner#retry_workflow`
  marks failed attempts as `:aborted` so the per-node attempt budget
  resets across workflow retries.
- `Memory::Storage` is single-process only. The mutable bookkeeping lives
  in `DAG::Adapters::Memory::StorageState`, which is the ONLY spot under
  `lib/dag/**` allowed to mutate hashes in place. The
  `Dag/NoInPlaceMutation` cop scopes only the pure-kernel files
  (`event.rb`, `proposed_mutation.rb`, `replacement_graph.rb`,
  `run_result.rb`, `runtime_profile.rb`, `step_input.rb`, `types.rb`,
  `waiting.rb`) plus everything under `lib/dag/ports/`. Memory adapters
  and the immutability primitives are excluded.
- The Runner is frozen after `initialize` and never holds mutable state.
  All state lives behind the storage port.
- `Runner.new` requires every keyword argument (`storage:, event_bus:,
  registry:, clock:, id_generator:, fingerprint:, serializer:`); a
  missing or `nil` keyword raises `ArgumentError`.
- No `Thread`, `Mutex`, `Queue`, `Ractor`, `Monitor`, or `ConditionVariable`
  anywhere in `lib/dag/**`. The `Dag/NoThreadOrRactor` cop enforces this
  globally.
- Event types are the closed set in `DAG::Event::TYPES`. The Runner
  emits `:workflow_started` once per workflow (idempotent via event log
  inspection), `:node_started` / `:node_committed` / `:node_waiting` /
  `:node_failed` per attempt, and one terminal
  `:workflow_completed` / `:workflow_waiting` / `:workflow_paused` /
  `:workflow_failed`.
- `Memory::Storage` events get a monotonic `seq`; `read_events(after_seq:,
  limit:)` filters by it. `EventBus#publish` sees the same stamped event
  the storage appended.
- **`Runner#call` finalization** follows Roadmap v3.4 §R1 line 565: if
  the per-layer loop exits with no eligible nodes and the workflow is
  not complete, the workflow transitions to `:failed` with event
  payload `{diagnostic: :no_eligible_but_incomplete}`. It does NOT
  fall back to `:waiting` — `:waiting` only fires when at least one
  node is in state `:waiting`.
- **`begin_attempt` is a pure writer.** The Runner computes
  `attempt_number = storage.count_attempts(...) + 1` before calling
  `storage.begin_attempt(..., attempt_number:)` (Roadmap §R1 lines
  522-525). The storage adapter does not own the numbering rule —
  this matters when SQLite arrives in S0 because the count and the
  insert can share one transaction.
- **`workflow_started` is emitted once per workflow lifetime**, not per
  `Runner#call`. The Runner detects prior emission by scanning the
  event log via `Storage#read_events`. After `Runner#retry_workflow`
  the workflow goes back to `:pending` and `#call` runs again, but
  `workflow_started` is not re-emitted.
- Hot-path graph iteration uses `each_predecessor` / `each_successor`
  rather than `predecessors` / `successors`, which dup the internal
  Set every call. The Runner's `build_run_context` precomputes
  `predecessors_by_node` once per `Runner#call` so per-node lookups
  are O(1) Hash reads.

## Roadmap board hygiene

Issues live on GitHub Project #2 (`ruby-dag Roadmap v3.4`,
`PVT_kwHOAAsSz84BVsbw`). The `Roadmap Status` field
(`PVTSSF_lAHOAAsSz84BVsbwzhRGfOs`) has options
`Backlog | Ready | In Progress | Blocked | Done`. **Update at every
transition** — it is the source of truth for what's in progress, ready,
blocked, or done.

- New issues triaged but not scheduled → `Backlog` (`92bab679`).
- Issue reviewed and a plan written → `Ready` (`cbe5fa16`).
- PR opened or work actively in progress → `In Progress` (`17602557`).
- Work paused on an external dependency → `Blocked` (`77d114c8`).
- PR merged → `Done` (`0372fd32`).

Update via:

```bash
gh project item-edit \
  --id <ITEM_ID> \
  --field-id PVTSSF_lAHOAAsSz84BVsbwzhRGfOs \
  --project-id PVT_kwHOAAsSz84BVsbw \
  --single-select-option-id <OPT_ID>
```

Look up `ITEM_ID` with
`gh project item-list 2 --owner duncanita --format json | jq '.items[] | select(.content.number == <N>) | .id'`.
