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
metadata
```

`metadata` is opaque to the kernel and must remain JSON-safe for durable
workflows.

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
