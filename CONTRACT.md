# ruby-dag Boundary Contract

`ruby-dag` is an implementation-agnostic DAG execution kernel. Its public
contract defines where kernel scheduling and durable execution protocols end and
consumer application behavior begins.

## Kernel Boundary

`ruby-dag` owns only:

- graph, definition, revision, and scheduling semantics;
- `Runner` orchestration over injected ports;
- step result transport;
- abstract effect intent reservation and dispatch coordination;
- mutation/revision APIs;
- retry/recovery rules;
- event log and diagnostic contract.

### Non-goals

Consumers own:

- concrete storage adapters beyond memory examples;
- concrete effect handlers;
- LLM/model/tool semantics;
- application-level budgets, approvals, policy, and UI streaming;
- consumer-owned runtime/domain objects, orchestration facades, per-run
  application context/results, and channel/stream behavior.

## Step Protocol

Steps implement:

```text
#call(StepInput) -> Success | Waiting | Failure
```

Steps should be frozen. Durable workflow inputs and outputs must be JSON-safe.
`Success` and `Failure` include the `DAG::Result` monadic helpers such as
`and_then`, `map`, and `recover`. `Waiting` is a valid step outcome, but it is
not a `DAG::Result`: it parks execution and is handled by the Runner state
machine instead of by value-level chaining.

Steps are idempotent functions of their `StepInput`: the same input should
produce the same `Success`, `Waiting`, or `Failure`, excluding trace metadata.
The kernel guarantees at-most-once result commit, not at-most-once invocation.
For abstract effects, the storage contract guarantees durable intent
reservation. Consumers still own exactly-once protection against concrete
external systems through remote idempotency keys, reconciliation, or equivalent
application logic.

## Step Result Contract

The kernel transports these fields without assigning consumer semantics:

```text
value
context_patch
proposed_mutations
proposed_effects
metadata
```

`metadata` is opaque to the kernel and must remain JSON-safe for durable
workflows.

`proposed_effects` is an Array of `DAG::Effects::Intent`. On `Success`, effects
are detached: they describe external work that does not block committing the
node. On `Waiting`, effects are blocking: they describe external work that must
finish before the step can produce its final result. The Runner prepares these
intents with execution coordinates and payload fingerprints, then storage
reserves them atomically with the attempt commit. Dispatch and concrete
handlers remain outside the runner.

## Effects Value Layer

An effect is described as an abstract, adapter-agnostic intent:

```ruby
DAG::Effects::Intent[type:, key:, payload: {}, metadata: {}]
```

`type` and `key` are Strings. `Intent#ref` is deterministic and equal to
`"#{type}:#{key}"`. `(type, key)` is the semantic identity of the effect;
payload is JSON-safe data that later storage adapters guard with a stable
payload fingerprint. Metadata is JSON-safe and opaque to the kernel.

The public value layer also exposes:

```ruby
DAG::Effects::PreparedIntent.from_intent(intent:, workflow_id:, revision:,
                                        node_id:, attempt_id:,
                                        payload_fingerprint:, blocking:,
                                        created_at_ms:)
DAG::Effects::Record.from_prepared(id:, prepared_intent:, status:,
                                   updated_at_ms:)
DAG::Effects::HandlerResult.succeeded(result:, external_ref: nil)
DAG::Effects::HandlerResult.failed(error:, retriable:, not_before_ms: nil)
```

All effect value objects are immutable and deep-freeze their JSON-safe
payloads. Effect records use the closed status set:

```ruby
EFFECT_STATUSES = %i[
  reserved
  dispatching
  succeeded
  failed_retriable
  failed_terminal
].freeze
```

Steps can compose awaited effects with:

```ruby
DAG::Effects::Await.call(input, intent, not_before_ms: nil) do |result|
  DAG::Success[value: result]
end
```

`Await` reads `input.metadata[:effects][intent.ref]`. If no snapshot exists,
or the effect is still pending/retriable, it returns
`Waiting[reason: :effect_pending, proposed_effects: [intent]]`. If the snapshot
is `:succeeded`, it yields the durable effect result to the continuation and
requires the continuation to return a legal step result. If the snapshot is
`:failed_terminal`, it returns a non-retriable `Failure`.

## Runner Effect Integration

Every step input includes an effect snapshot scoped to the current workflow
revision and current node:

```ruby
input.metadata[:effects]
```

The snapshot is a JSON-safe Hash keyed by effect `ref`. Values are plain frozen
Hashes, not `DAG::Effects::Record` objects, so `StepInput` remains durable and
JSON-safe. `DAG::Effects::Record#to_snapshot` returns this public shape. The
snapshot contains stable effect data:

```text
id
ref
type
key
payload
payload_fingerprint
blocking
status
result
error
external_ref
not_before_ms
metadata
```

Lease fields and storage timestamps are intentionally excluded from
`StepInput`; they are dispatcher coordination data, not step input data.

When a step returns `Success` or `Waiting` with `proposed_effects`, the Runner
converts each `Intent` into a `PreparedIntent` before calling storage. It uses
the injected fingerprint port to compute `payload_fingerprint` from
`intent.payload`, fills in workflow/revision/node/attempt coordinates, and sets
`blocking: true` for `Waiting` and `blocking: false` for `Success`.

For `:node_waiting` events, the durable event payload includes:

```ruby
effect_refs: [...]
effect_count: Integer
```

## StepInput Runtime Snapshot

Steps can read the public runtime boundary through:

```ruby
snapshot = input.runtime_snapshot
```

`input.runtime_snapshot` returns an immutable `DAG::RuntimeSnapshot` with the
current workflow id, revision, node id, attempt id, and attempt number. It also
carries the same `DAG::PlanVersion` coordinate as `snapshot.plan_version`.

The snapshot includes predecessor snapshots under `#predecessors`. These
predecessor snapshots are limited to canonical committed `Success` results for
the current revision and are keyed by predecessor node id. Each value is a
plain frozen Hash with:

```text
value
context_patch
metadata
```

Predecessor lookup uses storage's canonical committed-result projection when
available, so preserved nodes after a revision append can contribute explicit
current-revision context without exposing older attempts. It does not expose
unrelated node attempts or implicit results from older revisions.

The snapshot includes node-scoped effect snapshots for the current
workflow/revision/node under `#effects`. Values are the same public frozen Hashes
used by `input.metadata[:effects]`; they contain stable effect data only. The
snapshot does not expose lease owners, lease deadlines, storage timestamps,
unrelated node attempts, or consumer runtime objects.

`#metadata` is reserved for JSON-safe extension metadata supplied by the kernel
or future compatible adapters. It is intentionally separate from the internal
`StepInput#metadata` carrier so steps get a stable public runtime shape instead
of storage internals. All nested values in `RuntimeSnapshot` are JSON-safe and
deep-frozen.

## Diagnostic Values

The kernel exposes two immutable, JSON-safe diagnostic value objects for
consumers that need to render or persist execution state without depending on
adapter internals:

```ruby
DAG::TraceRecord.from_event(event)
DAG::Diagnostics.trace_records(storage:, workflow_id:, after_seq: nil, limit: nil)
DAG::Diagnostics.node_diagnostics(storage:, workflow_id:, revision: nil)
```

`DAG::TraceRecord` is a normalized view of the append-only event log. Its
public shape is:

```text
workflow_id
revision
node_id
attempt_id
at_ms
status
event_type
seq
payload
```

`status` is derived from the closed event type set (`:started`, `:success`,
`:waiting`, `:failed`, `:paused`, `:completed`, or `:mutation_applied`) while
`event_type`, `seq`, and `payload` preserve the durable event coordinates.

`DAG::NodeDiagnostic` summarizes the current node state for one workflow
revision. It is derived only from `load_node_states`, `list_attempts`, and
`list_effects_for_node`, and has this public shape:

```text
workflow_id
revision
node_id
state
terminal
attempt_count
last_attempt_id
last_error_code
last_error_attempt_id
waiting_reason
effect_refs
effect_statuses
effects_terminal
```

`last_error_attempt_id` attributes failures to the durable node attempt that
produced the last `Failure`; `last_error_code` is a String, Symbol, or Integer
when the failure payload provides a scalar `code`, and `nil` otherwise.
`waiting_reason` is populated only for currently
waiting nodes. `effect_refs` and `effect_statuses` are sorted by effect ref;
`effects_terminal` is `nil` when the node has no linked effects, otherwise it
reports whether all linked effects are terminal. Diagnostic values do not
expose prompt/model/tool/channel concepts, lease owners, adapter locks, or
consumer runtime objects.

## Effect Dispatcher Contract

`DAG::Effects::Dispatcher` is an abstract boundary coordinator. It claims
durable `DAG::Effects::Record` values from storage and calls consumer-provided
handlers; it does not know concrete external systems and is not used by
`DAG::Runner`.

Dispatcher construction is explicit:

```ruby
DAG::Effects::Dispatcher.new(
  storage:,
  handlers:,
  clock:,
  owner_id:,
  lease_ms:,
  unknown_handler_policy: :terminal_failure
)
```

`handlers` is a Hash keyed by effect type (`String` or `Symbol`). Each handler
must implement:

```text
#call(DAG::Effects::Record) -> DAG::Effects::HandlerResult
```

`tick(limit:)` claims up to `limit` ready effects with
`storage.claim_ready_effects`, dispatches each claimed record, and completes
the effect through storage. When the adapter implements
`complete_effect_succeeded` / `complete_effect_failed`, the terminal mark and
waiting-node release happen in one storage boundary. Older adapters may still
fall back to `mark_effect_succeeded` / `mark_effect_failed` followed by
`release_nodes_satisfied_by_effect`. The return value is an immutable
`DAG::Effects::DispatchReport`:

```text
claimed
succeeded
failed
released
errors
```

After a successful handler result or terminal failure, waiting nodes are
released only when every blocking effect linked to the waiting attempt is
terminal. Retriable failures do not release waiting nodes.
`DAG::Effects::StaleLeaseError` from a completion or mark operation is
recorded in `errors` and the tick continues with the remaining claimed
records.

Handler exceptions and invalid handler return values become retriable effect
failures with JSON-safe error payloads. Unknown effect types default to terminal
failure with `code: :unknown_handler`; alternatively,
`unknown_handler_policy: :raise` raises `DAG::Effects::UnknownHandlerError`.

Every entry in `DispatchReport#errors` has the shared JSON-safe keys:

```text
code
effect_id
ref
type
```

Code-specific entries may add fields. `:handler_raised` adds `class` and
`message`; `:handler_bad_return` adds `class`; `:stale_lease` adds `message`.

## Storage Receipts And Failure Vocabulary

Public storage methods must not require consumers to infer success from `nil`
or adapter-specific side effects. Every mutating operation returns the
shape documented in `DAG::Ports::Storage`:

- `create_workflow` -> `{id:, current_revision:}`.
- `transition_workflow_state` -> `{id:, state:, event:}` where `event` is the
  stamped event or `nil`.
- `transition_node_state` -> `{workflow_id:, revision:, node_id:, state:}`.
- `append_revision` and `append_revision_if_workflow_state` ->
  `{id:, revision:, event:}`.
- `begin_attempt` -> the durable attempt id string.
- `commit_attempt` -> the stamped durable `DAG::Event`.
- `claim_ready_effects` -> claimed `DAG::Effects::Record` snapshots.
- `mark_effect_succeeded` and `mark_effect_failed` -> the updated
  `DAG::Effects::Record`.
- `complete_effect_succeeded` and `complete_effect_failed` ->
  `{record:, released:}`.
- `release_nodes_satisfied_by_effect` -> release receipts shaped as
  `{workflow_id:, revision:, node_id:, attempt_id:, released_at_ms:}`.
- `abort_running_attempts` -> aborted attempt ids.
- `append_event` -> stamped `DAG::Event` with monotonic `seq`.
- `prepare_workflow_retry` ->
  `{id:, state:, reset:, workflow_retry_count:, event:}`.

Storage adapters use the shared public error vocabulary for control flow:
`DAG::UnknownWorkflowError`, `DAG::StaleStateError`,
`DAG::StaleRevisionError`, `DAG::ConcurrentMutationError`,
`DAG::WorkflowRetryExhaustedError`, `DAG::Effects::UnknownEffectError`,
`DAG::Effects::IdempotencyConflictError`, and
`DAG::Effects::StaleLeaseError`. Exception messages are diagnostics only;
Runner and consumers must branch on classes and structured receipts rather than
parsing adapter-specific text.

## Effect Storage Contract

Effect reservation is part of the attempt commit atomic boundary:

```ruby
storage.commit_attempt(attempt_id:, result:, node_state:, event:, effects: [])
```

`effects` contains `DAG::Effects::PreparedIntent` values. Adapters must persist
the attempt result, attempt state, node state, durable event, effect records,
and attempt-effect links in one logical transaction. If effect reservation
raises, the attempt, node state, event log, and links must remain unchanged.

Effect identity is semantic and global to the storage adapter:

```text
identity = [type, key]
ref      = "#{type}:#{key}"
```

`type` and `key` are Strings and must not contain `:`. The separator is
reserved so the string `ref` is an unambiguous representation of
`[type, key]`.

The first reservation for a `ref` creates a durable `DAG::Effects::Record` in
`:reserved`. A later reservation with the same `ref` and the same
`payload_fingerprint` reuses the record and adds a new attempt-effect link. A
later reservation with the same `ref` and a different `payload_fingerprint`
raises `DAG::Effects::IdempotencyConflictError`.

The storage effect API is:

```ruby
storage.list_effects_for_node(workflow_id:, revision:, node_id:)
storage.list_effects_for_attempt(attempt_id:)
storage.claim_ready_effects(limit:, owner_id:, lease_ms:, now_ms:)
storage.mark_effect_succeeded(effect_id:, owner_id:, result:, external_ref:, now_ms:)
storage.mark_effect_failed(effect_id:, owner_id:, error:, retriable:, not_before_ms:, now_ms:)
storage.complete_effect_succeeded(effect_id:, owner_id:, result:, external_ref:, now_ms:)
storage.complete_effect_failed(effect_id:, owner_id:, error:, retriable:, not_before_ms:, now_ms:)
storage.release_nodes_satisfied_by_effect(effect_id:, now_ms:)
```

`claim_ready_effects` may claim records in `:reserved`, records in
`:failed_retriable` whose `not_before_ms` is absent or due, and records in
`:dispatching` whose lease has expired. Claiming sets `status: :dispatching`,
`lease_owner`, `lease_until_ms`, and `updated_at_ms` atomically. A non-expired
lease cannot be claimed by another owner.

`mark_effect_succeeded` and `mark_effect_failed` require the current lease
owner and a non-expired lease; otherwise they raise
`DAG::Effects::StaleLeaseError`. Success sets `status: :succeeded` and stores
the JSON-safe result and external reference. Retriable failure sets
`status: :failed_retriable`, stores the JSON-safe error, and may set
`not_before_ms`. Terminal failure sets `status: :failed_terminal`.

`:succeeded` and `:failed_terminal` are terminal effect states.
`release_nodes_satisfied_by_effect` resets linked nodes from `:waiting` to
`:pending` only when every blocking effect linked to that waiting attempt is
terminal. Detached effects (`blocking: false`) never hold a node in
`:waiting`.

`complete_effect_succeeded` and `complete_effect_failed` are the durable
completion boundary for dispatchers. They perform the same lease validation and
state update as `mark_effect_succeeded` / `mark_effect_failed` and also release
any newly satisfied waiting nodes in the same logical storage transaction.
They return `{record:, released:}`. Retriable failures return an empty
`released:` array.

## Storage Behavioral Contract Suite

Reusable storage adapters should validate the public durability boundary by
requiring `dag/testing/storage_contract`, including
`DAG::Testing::StorageContract::All` in their own adapter test, and
implementing:

```ruby
def build_contract_storage
  MyAdapter::Storage.new
end
```

The shared suite is behavior-oriented: failures describe the public storage
contract instead of depending on `DAG::Adapters::Memory::Storage` internals. It
covers these groups:

- **G1** workflow create/load/current revision.
- **G2** atomic workflow state transition plus optional event append.
- **G3** begin/commit attempt one-shot semantics.
- **G4** deterministic canonical predecessor result selection.
- **G5** atomic effect reservation and idempotency conflict rollback.
- **G6** effect claim/lease ownership and stale lease protection.
- **G7** terminal effect completion and waiting-node release.
- **G8** atomic workflow retry and retry-budget enforcement.
- **G9** revision append CAS plus workflow-state guard.
- **G10** durable event ordering and filtering.
- **G11** immutable/fresh returned values.
- **G12** standard receipt and error/failure vocabulary.
- **G13** no consumer-specific semantics in the storage contract.

`DAG::Adapters::Memory::Storage` runs the suite in this repository. Consumer or
production adapters can reuse the same module to prove conformance without
copying memory-adapter implementation details into their own tests.

## V1.1 Consumer Compatibility Matrix

V1.1 is a contract release. Stable consumer APIs are the public kernel boundary
that durable hosts can adopt without depending on memory-adapter internals:

- `DAG::Runner#call`, `DAG::Runner#resume`, and
  `DAG::Runner#retry_workflow` for pending, recovery, and explicit retry
  entry points.
- `DAG::Workflow::Definition`, `DAG::PlanVersion`, `DAG::RuntimeProfile`,
  `DAG::Success`, `DAG::Waiting`, `DAG::Failure`, and `DAG::StepInput` for
  immutable workflow data and result transport.
- `DAG::RuntimeSnapshot` for step-visible workflow/revision/node coordinates,
  canonical predecessor values, and scoped effect snapshots.
- `DAG::Effects::{Intent, PreparedIntent, Record, HandlerResult,
  DispatchReport}` and `DAG::Effects::Dispatcher` for abstract effect
  reservation and dispatch coordination.
- `DAG::TraceRecord`, `DAG::NodeDiagnostic`, and `DAG::Diagnostics` for
  consumer-facing trace and node state projection.
- `DAG::DefinitionEditor` and `DAG::MutationService` for immutable structural
  planning and guarded mutation application.
- `DAG::Testing::StorageContract::All` for reusable storage conformance.

Durable adapter adoption checklist:

### Required for durable adapters

- Persist workflows, definition revisions, node states, attempts, effect
  records, attempt-effect links, and event logs durably and atomically at the
  documented boundaries.
- Implement the full `DAG::Ports::Storage` method set and return the documented
  receipt shapes for every mutating operation.
- Preserve the public failure vocabulary: `UnknownWorkflowError`,
  `StaleStateError`, `StaleRevisionError`, `ConcurrentMutationError`,
  `WorkflowRetryExhaustedError`, `Effects::UnknownEffectError`,
  `Effects::IdempotencyConflictError`, and `Effects::StaleLeaseError`.
- Bind workflow terminal state transitions and their durable events in one
  storage boundary through `transition_workflow_state(..., event:)`.
- Bind retry state CAS, retry-budget enforcement, failed-node reset, aborted
  failed attempts, workflow state transition, and optional event append inside
  `prepare_workflow_retry`.
- Bind mutation workflow-state guard and revision CAS inside
  `append_revision_if_workflow_state`.
- Make `commit_attempt` one-shot and persist attempt result, node state, event,
  and effect reservations in one logical transaction.
- Implement effect claim/lease/completion semantics, including atomic terminal
  completion with waiting-node release through `complete_effect_succeeded` and
  `complete_effect_failed`.
- Return immutable or fresh values from all read methods so consumers cannot
  mutate adapter state through returned objects.
- Run `DAG::Testing::StorageContract::All` against the adapter and keep all
  G1-G13 groups passing.

### Recommended for durable adapters

- Implement `list_committed_results_for_predecessors` so runners can load
  canonical predecessor results and carried-forward committed projections in a
  single adapter-owned query.
- Namespace effect keys by workflow, revision, and node at the consumer edge so
  global `(type, key)` effect identity cannot collide across workflow runs.
- Store enough indexed event, attempt, node, and effect data for
  `DAG::Diagnostics.trace_records` and `DAG::Diagnostics.node_diagnostics` to
  remain cheap and deterministic.
- Treat retry exhaustion, waiting, and paused workflows as bounded kernel
  outcomes and expose consumer-owned alerting, approval, backoff, and
  replacement-workflow policy outside the adapter.

### Optional for simple consumers

- Use `DAG::Toolkit.in_memory_kit` and `DAG::Adapters::Memory::Storage` for
  single-process examples, tests, or ephemeral scripts.
- Omit concrete effect handlers when workflows do not use `proposed_effects`.
- Skip live event-bus publication by injecting `DAG::Adapters::Null::EventBus`
  when durable event-log reads are sufficient.

## Execution Context

Execution context is a copy-on-write dictionary managed by the kernel. Keys and
values are chosen by the consumer, and must be JSON-safe for durable workflows.

## Plan Versions And Revisions

A plan version is the immutable coordinate `{workflow_id, revision}` exposed as
`DAG::PlanVersion`. `revision` is `Definition#revision`; storage records it on
workflow definitions, node states, attempts, events, effect links, and committed
result projections.

A `Runner` call evaluates exactly one plan version. It loads the current
`Definition` once at the start of the call, builds the scheduling context for
that revision, and does not mix node states, attempts, or effect snapshots from
other revisions during that scheduling pass.

Structural mutation never edits the active definition in place. Applying a
mutation appends `parent_revision + 1` behind the storage CAS guard. Older
revisions remain loadable by exact revision and must return the graph and step
mapping that were current before the mutation.

Committed results from older revisions do not leak into a new revision by
implicit lookup. When a preserved node remains `:committed` after a revision
append, storage may materialize an explicit committed-result projection in the
new plan version. That projection carries the previous canonical `Success`
result for downstream context assembly, but it is not an attempt, does not
increment attempt counts, and does not cause the preserved node to rerun.
Invalidated nodes and newly introduced nodes have no carry-forward projection.

## State Model

Workflow states:

```ruby
WORKFLOW_STATES = %i[
  pending
  running
  waiting
  paused
  completed
  failed
].freeze
```

Allowed workflow transitions:

| From | To | Cause |
|---|---|---|
| `pending` | `running` | `Runner#call` |
| `waiting` | `running` | `Runner#resume` or an external consumer event |
| `paused` | `running` | `Runner#resume` after mutation or approval |
| `running` | `completed` | all nodes committed |
| `running` | `waiting` | at least one step returned `Waiting` and no eligible node remains |
| `running` | `paused` | a step returned `Success` with proposed mutations |
| `running` | `failed` | non-retriable failure or retry exhaustion |

Node states are scoped to a definition revision:

```ruby
NODE_STATES = %i[
  pending
  running
  committed
  waiting
  failed
  invalidated
].freeze
```

Attempt states:

```ruby
ATTEMPT_STATES = %i[
  running
  committed
  waiting
  failed
  aborted
].freeze
```

Only a committed attempt for the current definition revision or an explicit
committed-result projection for that revision contributes to the effective
context. When more than one committed attempt exists for a node, the canonical
attempt is the highest `attempt_number`, with `attempt_id.to_s` ASCII as a
defensive tie-break. Storage adapters may expose
`list_committed_results_for_predecessors(workflow_id:, revision:, predecessors:)`
to return those canonical `Success` results in one call; Runner falls back to
`list_attempts` when the extension is absent, which can only observe real
attempts and not adapter-owned projections.

## Resume And Crash Recovery

`Runner#resume(workflow_id)` can resume workflows in `:running`, `:waiting`, or
`:paused`. A `:running` workflow means the previous process may have crashed
before reaching a terminal state.

Before recomputing eligibility, resume calls:

```ruby
storage.abort_running_attempts(workflow_id:)
```

The storage operation marks in-flight attempts as `:aborted` and resets any
matching current-revision node still in `:running` back to `:pending`. Nodes
already `:committed` are never rerun in that revision. Nodes in `:waiting` are
not rerun automatically; a consumer must make an explicit app-level decision
and update state/context before retrying them. Retry exhaustion, waiting, and
paused states are bounded kernel outcomes; consumers own escalation policy,
alerting, approval, backoff, and replacement workflows.

`commit_attempt` is the atomic durability boundary for node execution. When it
returns, result, attempt state, node state, the durable event, and any prepared
effect reservations are committed together. If a process crashes before that
boundary, the step may be invoked again on resume. If it crashes after the
boundary, resume starts from the next eligible node.

`transition_workflow_state` is the equivalent atomic durability boundary for
**workflow-level** state changes. It accepts an optional `event:` keyword:

```ruby
storage.transition_workflow_state(id:, from:, to:, event: nil)
# returns {id:, state:, event: stamped_or_nil}
```

When `event:` is supplied, the row transition and the event append happen in
the same atomic step. The Runner uses this for every terminal and
quasi-terminal transition (`:running -> :completed`, `:running -> :failed`,
`:running -> :paused`, `:running -> :waiting`) so that a crash can never
leave the workflow row in a terminal state without its corresponding
terminal event in the log. The `event:`-less form is reserved for internal
transitions that have no associated event (e.g. `:pending -> :running` in
`acquire_running`, where `:workflow_started` is emitted later by an
idempotent path that scans the event log).

This is a port extension over the canonical roadmap signature
`(id:, from:, to:)`. See `CLAUDE.md` "Port extensions" for the full
justification. SQLite (S0) implements the same atomicity via a single
transaction.

`prepare_workflow_retry` is the atomic durability boundary for explicit
workflow retry:

```ruby
storage.prepare_workflow_retry(id:, from: :failed, to: :pending, event: nil)
# returns {id:, state:, reset:, workflow_retry_count:, event: stamped_or_nil}
```

The operation checks the workflow is still in `from` and that
`workflow_retry_count < max_workflow_retries`, aborts failed attempts
for failed nodes in the current revision, resets those nodes to `:pending`,
increments `workflow_retry_count`, transitions the workflow to `to`, and
optionally appends `event:` in the same storage step. `Runner#retry_workflow`
must not follow this with a separate `transition_workflow_state`, and must
not pre-check the budget outside the atomic boundary: a stale read of
`workflow_retry_count` between two concurrent retries (with the workflow
re-failing in between) would let both pass the Ruby-level check and bypass
the budget. The atomic guard inside `prepare_workflow_retry` is the source
of truth for both the state CAS and the retry budget.

The Runner owns attempt numbering. It computes:

```ruby
storage.count_attempts(workflow_id:, revision:, node_id:) + 1
```

and passes that value to:

```ruby
storage.begin_attempt(workflow_id:, revision:, node_id:,
                      expected_node_state:, attempt_number:)
```

Storage must persist the supplied `attempt_number`; it must not recalculate it.
`commit_attempt` is one-shot: adapters must reject a second commit for the same
attempt after it has left `:running`.

## Proposed Mutations

Consumers may propose mutations with:

```text
kind
target_node_id
replacement_graph
rationale
confidence
metadata
```

Applications apply mutations through:

```ruby
DAG::MutationService#apply(workflow_id:, mutation:, expected_revision:)
```

Definitions must not apply storage side effects directly.

`DAG::DefinitionEditor#plan(definition, mutation) -> PlanResult` is the pure
planning API. It does not read storage, publish events, or mutate the supplied
definition. `PlanResult` exposes:

```text
valid?
new_definition
invalidated_node_ids
reason
```

For `:invalidate`, `invalidated_node_ids` is the target node plus all of its
descendants. For `:replace_subtree`, the editor removes only the target's
exclusive descendants, reconnects the replacement graph through explicit
`entry_node_ids` and `exit_node_ids`, preserves independent parallel branches,
and invalidates preserved descendants whose inputs may have changed.

`ReplacementGraph` is structural in R3. It carries graph shape plus explicit
entry and exit node ids; it does not infer entry/exit from roots or leaves. New
replacement nodes are registered in the returned definition as built-in `:noop`
steps.

`DAG::MutationService#apply(workflow_id:, mutation:, expected_revision:)`
is the only kernel API that applies structural side effects. It requires the
workflow to be in `:paused` or `:waiting`. If the workflow is `:running`, it
raises `ConcurrentMutationError`; if the stored revision no longer matches
`expected_revision`, it raises `StaleRevisionError`.

On success, mutation apply appends the new definition revision using storage
CAS, marks invalidated preserved nodes `:invalidated`, initializes newly
introduced nodes as `:pending`, materializes committed-result projections for
preserved committed nodes, durably appends `mutation_applied`, and only then
publishes that event through `EventBus#publish`.

Durable adapters should implement:

```ruby
storage.append_revision_if_workflow_state(
  id:,
  allowed_states: %i[paused waiting],
  parent_revision:,
  definition:,
  invalidated_node_ids:,
  event:
)
```

This port extension binds the workflow-state guard and revision CAS inside one
storage boundary. If the workflow becomes `:running` between the service's
initial read and the append, storage raises `ConcurrentMutationError` and the
revision/event log remain unchanged.

## Events

The coarse event list is closed:

```ruby
EVENT_TYPES = %i[
  workflow_started
  node_started
  node_committed
  node_waiting
  node_failed
  workflow_paused
  workflow_waiting
  workflow_completed
  workflow_failed
  mutation_applied
].freeze
```

Events are durably appended by storage operations, then published live through
`EventBus#publish` after commit.

## Runtime Profile

Runtime profile fields:

```text
durability
max_attempts_per_node
max_workflow_retries
event_bus_kind
metadata
```

The value is frozen and JSON-safe. Defaults are `max_attempts_per_node: 3` and
`max_workflow_retries: 0`. A retry budget of `0` means
`Runner#retry_workflow` raises `WorkflowRetryExhaustedError` immediately;
choose a positive value, commonly `3`, for workflows that should be manually
retryable after failure.

## Step Type Registry

Consumers register custom step types with:

```ruby
register(name:, klass:, fingerprint_payload:, config: {}, cache_instances: false)
```

The fingerprint must be stable and deterministic.
`cache_instances: true` lets the Runner reuse one frozen step instance per
`(type, config)` during a call. The default is `false` so stateful user step
classes keep the historical per-attempt instantiation behavior.
