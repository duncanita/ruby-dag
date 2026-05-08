# Changelog

## Unreleased

## 1.3.0 — 2026-05-08

V1.3 introduces bounded intra-tick parallel dispatch so consumers can
fan out N co-eligible effects (e.g. tool calls and LLM calls in a
single workflow) instead of paying `N × per_record` wall time. The
opt-in is a single additive kwarg; the default is identical to V1.2.

### Added

- `DAG::Effects::Dispatcher.new(parallelism: 1)` (default) preserves
  the V1.2 serial contract bit-identical. Values `> 1` claim records
  as before but dispatch them through a bounded worker pool of at
  most `parallelism` `Thread.new` workers in flight regardless of
  batch size. The pool reads from a `Queue` of `[record, slot_index]`
  pairs and writes outcomes into a pre-allocated `Array.new(N)` at
  the matching slot, so `succeeded.map(&:id)` is a subsequence of
  `claimed.map(&:id)` in original order. Unexpected exceptions raised
  inside a worker thread propagate out of `#tick` *only after every
  worker has joined*: each worker rescues every exception, parks it
  in a shared error list, sets a shared abort flag that stops peer
  workers from pulling new records (peers still finish the record
  they were already processing), and exits its loop normally. After
  `workers.each(&:join)` returns, `#tick` raises the first captured
  exception. This guarantees that no worker is still mutating storage
  when `#tick` raises, preserving the V1.2 serial-map exception
  semantics where the caller observes a stable post-tick state.
- `parallelism > 1` requires the storage adapter to declare
  thread-safety by implementing `#thread_safe_for_dispatch?` returning
  truthy. Adapters that do not declare it cause
  `Dispatcher.new(..., parallelism: > 1)` to raise `ArgumentError`,
  surfacing the contract mismatch at construction instead of at
  runtime. `DAG::Adapters::Memory::Storage` is single-process by
  Roadmap §2.4 and intentionally does not declare it; durable
  adapters (typically SQLite-backed) bind every dispatcher-touched
  method to a transaction and declare it explicitly.

### Changed

- Roadmap v3.4 §2.4 / §9.1 carve out a single V1.3+ exception against
  two cop gates so bounded parallel dispatch can be implemented inside
  the kernel:
  - `Dag/NoThreadOrRactor` lets `lib/dag/effects/dispatcher.rb` use
    `Thread.new` and `Queue` for the worker pool. `Thread.start` and
    `Thread.fork` stay banned even in this file: bounded
    `parallel_map` does not need them, and keeping them blocked closes
    the gap between the documented carve-out and the cop allow-list.
  - `Dag/NoInPlaceMutation` lets the same file use `<<`, `pop`, and
    `[]=` for queue feed, worker drain, and slot-indexed result
    writes.
  Both cops use the same `dispatcher_relaxed_file?` predicate.
  `Mutex`, `Monitor`, `SizedQueue`, `ConditionVariable`, `Fiber`,
  `Process.fork`/`spawn`/`daemon`, `Ractor`, and the other mutating
  ops (`merge!`, `update`, `delete`, `clear`, `shift`, `push`)
  remain banned even in the dispatcher. Tests in
  `spec/r0/rubocop_cops_test.rb` cover both cops' allow-lists
  (Thread/Queue and `<<`/`pop`/`[]=` in the dispatcher) and the
  still-banned cases (Mutex and `merge!` in the dispatcher; Thread in
  the runner; `<<` in other `lib/dag/effects/**` files). Rationale: the
  Dispatcher is already an I/O-bound boundary and already
  non-deterministic by design (handlers complete in network/LLM/disk
  order), so allowing intra-tick parallelism does not move the §2.1
  Determinism pillar — Runner, Memory adapters, and every other
  `lib/dag/**` file remain single-threaded and pure-value. The
  `parallelism:` kwarg itself ships with the V1.3 feature release;
  this changelog entry documents only the governance carve-out it
  depends on. `CONTRACT.md` gains a "Dispatcher Concurrency Contract"
  subsection covering storage and handler thread-safety
  responsibilities and the `Memory::Storage` + `parallelism > 1`
  `ArgumentError` rule.

### Added

- `DAG::Event::TYPES` gains `:effect_dispatch_stale_lease`, emitted by
  `DAG::Effects::Dispatcher` when a handler returns but the storage lease
  has already expired and the completion mark cannot be applied. The
  dispatcher appends the event durably via `storage.append_event` before
  recording the in-memory `DispatchReport#errors` entry, so the failure
  mode is visible in the workflow event log instead of having to be
  reconstructed from process-local state. Payload carries
  `code: :stale_lease`, `effect_id`, `ref`, `type`, `lease_owner`,
  `lease_until_ms`, and `message`.
- `DAG::TraceRecord::STATUSES` gains `:effect_dispatch_stale_lease` and
  the matching entry in `EVENT_STATUS`, mirroring the
  `mutation_applied` 1:1 mapping pattern so trace consumers can render
  the diagnostic without confusing it with a node-level failure.

### Changed

- `DAG::Effects::Dispatcher` now requires the storage adapter to
  implement `append_event`. The Memory adapter already does;
  `validate_storage!` is updated to reject adapters that don't.

## 1.2.0 — 2026-05-07

V1.2 extends the effect-aware storage contract with cooperative lease renewal
so dispatchers can keep their default `lease_ms` short (fast worker-death
recovery) while still letting legitimately long-running handlers extend
their own claim. Originated from a Delphi-side retry-storm trace
(workflows `7134e4d6` and `b540702c`, 2026-05-06) where a 30s default
`lease_ms` was shorter than legitimate LLM handler runtime (~110s),
causing repeated re-claims and duplicate paid external work.

### Added

- `DAG::Ports::Storage#renew_effect_lease(effect_id:, owner_id:, until_ms:,
  now_ms:)` cooperatively extends the lease of an effect currently held by
  `owner_id`. Applies the same lease CAS as `mark_effect_*` (status
  `:dispatching`, owner match, non-expired lease) and updates
  `lease_until_ms` and `updated_at_ms` atomically. Renewal is monotonic:
  `until_ms` must exceed `now_ms` and not shrink the current
  `lease_until_ms` (`ArgumentError` otherwise); `until_ms == lease_until_ms`
  is a no-op success. A stale, foreign, or non-`:dispatching` lease raises
  `DAG::Effects::StaleLeaseError`.
- `DAG::Adapters::Memory::Storage` implements `renew_effect_lease`.
- `DAG::Testing::StorageContract::Effects` extends G6 with renewal coverage:
  success, idempotency on equal `until_ms`, wrong owner, expired lease,
  unclaimed effect, unknown effect, and rejection of both `until_ms <= now_ms`
  and shrinking `until_ms`.
- API-stability guard tests for release documentation, runtime profile
  compatibility, and legacy mutation storage adapters.

### Changed

- Runtime profile, memory storage, and event values are hardened against
  mutable workflow, attempt, and event-bus-kind inputs without changing
  public API signatures.
- Effect key examples avoid `:` inside consumer-owned `type` and `key`
  parts so the `type:key` record identity stays unambiguous, and stale
  execution-plan wording is preserved as historical reference.

## 1.1.0 — 2026-05-03

V1.1 is a contract hardening release for durable consumers. RD-01 through RD-08
are complete, and this release contains no Delphi-specific implementation:
consumer repositories own concrete storage adapters, handlers, planning policy,
escalation policy, and product semantics.

### Added

- `DAG::RuntimeSnapshot` exposes immutable, JSON-safe workflow/revision/node
  coordinates plus scoped predecessor and effect snapshots for custom steps.
- `DAG::TraceRecord`, `DAG::NodeDiagnostic`, and `DAG::Diagnostics` now expose
  immutable, JSON-safe trace/node diagnostic values derived from durable events,
  attempts, node state, and effect records.
- `DAG::Testing::StorageContract::All` now groups the reusable storage adapter
  conformance suite around G1-G13 behavior: lifecycle, state transitions,
  attempts, canonical predecessor selection, effect ledger atomicity, leases,
  waiting-node release, workflow retry, revision CAS, event ordering,
  immutable reads, standard receipts/errors, and consumer-neutrality.
- A V1.1 consumer compatibility matrix documents stable kernel APIs and the
  required/recommended/optional durable adapter extension checklist.

### Changed

- Storage receipt contract tests now assert the documented return shapes for
  workflow/node transitions, revision append, workflow retry, and atomic effect
  completion, and the port docs require every public storage method to document
  its return value.
- Bounded recovery controls are explicitly documented and covered: retry
  exhaustion, waiting, and paused states are bounded kernel outcomes; consumers
  own escalation, alerting, approval, backoff, and replacement workflows.

## 1.0.1 — 2026-05-01

Patch release for the v1.0 kernel line. No runtime dependencies added and no
public API removals.

### Fixed

- Effect dispatch now validates leases against a fresh clock read per record,
  so long handler batches cannot mark records with stale batch-start time.
- Effect completion can atomically mark terminal effects and release waiting
  nodes through `complete_effect_succeeded` / `complete_effect_failed`,
  preventing crash gaps between mark and release.
- Effect refs reject ambiguous `type` / `key` parts containing `:`.
- Frozen graph layer caches now freeze their member arrays.
- Revision append is state-aware, avoiding stale mutation application.
- Memory event bus subscriber dispatch uses a stable callback snapshot.

### Changed

- Runner and value-object hot paths avoid avoidable storage reads,
  repeated ref construction, defensive copies, and snapshot projection work.
- Definition construction gained a bulk builder and cached structural hash.
- Validation and immutability helpers are reused consistently across value
  objects and adapters while preserving public error messages.
- Documentation clarifies workflow retry budgets, waiting-result semantics,
  storage return shapes, and DRY guidance for future agents.

## 1.0.0 — 2026-05-01

Roadmap v3.4 complete (R0-R3) plus the effect-aware kernel contract
required by Delphi. Deterministic kernel, durable in-memory resume,
structural mutation, abstract effect intents, lease-aware dispatch, and
the shared storage contract are in. Zero runtime dependencies; Ruby
≥ 3.4. The Memory adapters are single-process; SQLite (S0) lives in the
Delphi consumer (`nexus`, branch `delphi-v1`) and implements the public
`DAG::Ports::Storage` contract.

This release closes the v1.0 readiness gate (#74). Highlights:

- The four kernel pillars from Roadmap v3.4 §2 are enforced: pure DAG;
  immutable workflow definitions and tagged types; dependency-injected
  frozen Runner with seven ports; closed event types and durable
  append-only event log.
- `bundle exec rake` runs Minitest, Standard, and the four custom DAG
  RuboCop cops (`NoThreadOrRactor`, `NoMutableAccessors`,
  `NoInPlaceMutation`, `NoExternalRequires`) on every PR.
- Public API surface is documented with YARD; `bundle exec yard stats`
  reports ≥ 99 % documented.
- README ships a ≤10-line hello-world plus a minimal resume example.
  `DAG::Toolkit.in_memory_kit(registry:)` wires the four stdlib ports
  + memory storage + memory event bus for examples and tests.

### Added — Roadmap v3.4 R2/R3: resume and structural mutation

- `DAG::Runner#resume` resumes workflows in `:running`, `:waiting`, or
  `:paused`, aborting in-flight attempts before recomputing eligibility.
- `DAG::Adapters::Memory::CrashableStorage` supports deterministic crash
  injection and `#snapshot_to_healthy` for resume tests.
- `DAG::DefinitionEditor` and `DAG::MutationService` implement R3
  `:invalidate` and `:replace_subtree` planning/application with revision CAS
  and durable `mutation_applied` events.
- Storage attempt numbering is now supplied by the Runner via
  `begin_attempt(..., attempt_number:)`; storage persists the supplied number
  and rejects duplicate `commit_attempt` calls.
- Tagged types validate through `initialize`, so `.new`, `[]`, and `#with`
  share the same JSON-safety and closed-enum checks.

### Added — Effect-aware kernel contract

- `DAG::Effects::{Intent, PreparedIntent, Record, HandlerResult,
  DispatchReport}` value objects plus `DAG::Effects::Await` for pure awaited
  effect composition.
- `DAG::Success` and `DAG::Waiting` now accept `proposed_effects`.
  `Success` effects are detached; `Waiting` effects are blocking and release
  the node only after every linked blocking effect is terminal.
- `DAG::Runner` prepares effect intents, computes payload fingerprints via
  the injected fingerprint port, and commits prepared intents inside
  `storage.commit_attempt(..., effects: [])`.
- `DAG::Ports::Storage` includes the effect ledger API:
  `list_effects_for_node`, `list_effects_for_attempt`,
  `claim_ready_effects`, `mark_effect_succeeded`, `mark_effect_failed`,
  and `release_nodes_satisfied_by_effect`.
- `DAG::Effects::Dispatcher` coordinates abstract effect dispatch under
  leases while concrete handlers remain in the consumer host.
- Effect identity is `(type, key)`; a different `payload_fingerprint` for the
  same identity raises `DAG::Effects::IdempotencyConflictError`.

### Changed

- `DAG::Runner#call` now only accepts workflows in `:pending`. Use
  `DAG::Runner#resume` to recover workflows in `:waiting` or `:paused`.
- `DAG::RunResult` now validates `outcome:` and `metadata:` as JSON-safe
  on construction; passing `Time`, non-finite floats, or other non-JSON
  values raises `ArgumentError`.

### Added — Roadmap v3.4 R1: deterministic core runner and default adapters

- `DAG::Runner` — frozen kernel runner with seven injected ports
  (`storage`, `event_bus`, `registry`, `clock`, `id_generator`,
  `fingerprint`, `serializer`). `#call(workflow_id)` runs the layered
  algorithm from the roadmap; `#retry_workflow(workflow_id)` resets
  failed nodes and retries until `WorkflowRetryExhaustedError`.
- `DAG::Workflow::Definition` — immutable, chainable. `add_node(id,
  type:, config: {})` and `add_edge(from, to, **metadata)` return new
  frozen instances. `revision` starts at 1; `fingerprint(via:)` defers to
  the fingerprint port; `to_h` is canonical and ASCII-sorted.
- `DAG::ExecutionContext` — deep-frozen copy-on-write context.
  `merge` returns a new context; `to_h` returns a fresh deep-dup.
- `DAG::StepProtocol`, `DAG::Step::Base`, `DAG::StepTypeRegistry`.
  Re-registering the same step type with a different
  `fingerprint_payload` raises `FingerprintMismatchError`; lookup of an
  unknown step type raises `UnknownStepTypeError`.
- Built-in step types: `:noop` and `:passthrough` (no `:branch` in R1).
- Default adapters under `DAG::Adapters`:
  - `Stdlib::{Clock, IdGenerator, Fingerprint, Serializer}`
  - `Null::EventBus`
  - `Memory::EventBus` (single-process, bounded, deep-frozen reads)
  - `Memory::Storage` (single-process, full lifecycle: workflow CAS,
    revisions, node states, attempts with `:aborted` exclusion in
    `count_attempts`, append-only event log with monotonic `seq`)
- `Graph#descendants_of`, `#exclusive_descendants_of`,
  `#shared_descendants_of`, `#topological_order`, canonical
  ASCII-sorted `#to_h` for fingerprint-friendly serialization.

### Removed

- Legacy `DAG::Workflow::{Runner, Loader, Dumper, Registry, Validator,
  Condition, Mutation, Invalidation, ScheduledPolicy, ...}` and the
  whole `Workflow::Parallel` / `Workflow::Steps` trees. The legacy
  YAML CLI (`bin/dag`), the `examples/` directory, the legacy
  benchmarks, and ~30 legacy spec files are gone. R1 replaces them
  with a clean kernel; subsequent phases (R2/R3/Release) build on it.

### Added — Roadmap v3.4 R0 (landed as part of #122)

- `require "ruby-dag"` entrypoint, boundary port contracts, immutable
  tagged types, JSON-safety helpers, custom DAG cops, `CONTRACT.md`,
  and CI scaffolding for Ruby 3.4/head.

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
