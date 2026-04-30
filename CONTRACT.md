# ruby-dag Boundary Contract

`ruby-dag` exposes the kernel contracts below. Consumers own application
semantics, external side effects, approvals, budgets, and UI streaming.

## Step Protocol

Steps implement:

```text
#call(StepInput) -> Success | Waiting | Failure
```

Steps should be frozen. Durable workflow inputs and outputs must be JSON-safe.

Steps are idempotent functions of their `StepInput`: the same input should
produce the same `Success`, `Waiting`, or `Failure`, excluding trace metadata.
The kernel guarantees at-most-once result commit, not at-most-once invocation.
Consumers must protect external effects with their own ledgers.

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
finish before the step can produce its final result. PR1 validates and
transports these values only; durable reservation and dispatch are storage and
dispatcher concerns introduced by later effect-aware phases.

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

## Execution Context

Execution context is a copy-on-write dictionary managed by the kernel. Keys and
values are chosen by the consumer, and must be JSON-safe for durable workflows.

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

Only a committed attempt for the current definition revision contributes to the
effective context.

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
and update state/context before retrying them.

`commit_attempt` is the atomic durability boundary for node execution. When it
returns, result, attempt state, node state, and the durable event are committed
together. If a process crashes before that boundary, the step may be invoked
again on resume. If it crashes after the boundary, resume starts from the next
eligible node.

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
CAS, resets invalidated and newly introduced nodes to `:pending` in the new
revision, durably appends `mutation_applied`, and only then publishes that
event through `EventBus#publish`.

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
`max_workflow_retries: 0`.

## Step Type Registry

Consumers register custom step types with:

```ruby
register(name:, klass:, fingerprint_payload:, config: {})
```

The fingerprint must be stable and deterministic.
