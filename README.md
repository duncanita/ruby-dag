# ruby-dag

Deterministic DAG execution kernel for Roadmap v3.4. Zero runtime
dependencies; Ruby 3.4+.

## Quick start

```ruby
require "ruby-dag"
registry = DAG::StepTypeRegistry.new
registry.register(name: :passthrough, klass: DAG::BuiltinSteps::Passthrough, fingerprint_payload: {v: 1})
registry.freeze!
kit = DAG::Toolkit.in_memory_kit(registry: registry)
definition = DAG::Workflow::Definition.new.add_node(:a, type: :passthrough).add_node(:b, type: :passthrough).add_edge(:a, :b)
id = kit.runner.id_generator.call
kit.storage.create_workflow(id: id, initial_definition: definition, initial_context: {hello: "world"}, runtime_profile: DAG::RuntimeProfile.default)
kit.runner.call(id).state # => :completed
```

`DAG::RuntimeProfile.default` uses `max_workflow_retries: 0`: explicit
workflow retries are disabled unless you opt in. For workflows that should be
retryable, pass a profile with a positive `max_workflow_retries`; `3` is a
reasonable starting point for scripts and small durable consumers.

`DAG::Toolkit.in_memory_kit` is a convenience for examples and tests.
Production callers inject the public ports (`storage:`,
`event_bus:`, `registry:`, `clock:`, `id_generator:`, `fingerprint:`, and
`serializer:`) when constructing `DAG::Runner`; durable production adapters can
live in consumer repositories. Delphi can be treated as a reference consumer,
not part of the kernel contract.

> Non-normative reference-consumer note: consumer-owned runtime objects,
> application context, result wrappers, and channel behavior are examples of
> application semantics. A consumer wrapper is not `DAG::RunResult`, and
> reference-consumer choices do not constrain other consumers.

## Resume after waiting

A step that returns `Waiting` parks the workflow at `:waiting`. Once the
external condition is satisfied, `Runner#resume` drives the workflow to
completion without re-running already-committed nodes:

```ruby
class GateStep < DAG::Step::Base
  GATE = []
  def call(_input)
    if GATE.any?
      DAG::Success[value: :ok]
    else
      DAG::Waiting[reason: :external_dependency]
    end
  end
end

registry = DAG::StepTypeRegistry.new
registry.register(name: :gate, klass: GateStep, fingerprint_payload: {v: 1})
registry.freeze!

kit = DAG::Toolkit.in_memory_kit(registry: registry)
definition = DAG::Workflow::Definition.new.add_node(:gate, type: :gate)
id = kit.runner.id_generator.call
kit.storage.create_workflow(id: id, initial_definition: definition,
  initial_context: {}, runtime_profile: DAG::RuntimeProfile.default)

kit.runner.call(id).state    # => :waiting
GateStep::GATE << :open      # external signal arrives
kit.storage.transition_node_state(workflow_id: id, revision: 1,
  node_id: :gate, from: :waiting, to: :pending)
kit.runner.resume(id).state  # => :completed
```

`:waiting` nodes are not retried automatically — the consumer signals that
the wait condition is satisfied by transitioning the node back to
`:pending`. `Runner#resume` also recovers crashed processes: a workflow
left in `:running` is unwedged by aborting in-flight attempts before
recomputing eligibility. Already-committed nodes are not rerun in the
same revision.

## Step input runtime snapshot

Custom steps receive a `DAG::StepInput`. For workflow/runtime coordinates and
stable predecessor/effect data, prefer the public snapshot boundary:

```ruby
class InspectInputStep < DAG::Step::Base
  def call(input)
    snapshot = input.runtime_snapshot
    DAG::Success[value: {
      workflow_id: snapshot.workflow_id,
      revision: snapshot.revision,
      node_id: snapshot.node_id,
      attempt: snapshot.attempt_number,
      predecessor_values: snapshot.predecessors.transform_values { |p| p.fetch(:value) },
      effect_refs: snapshot.effects.keys
    }]
  end
end
```

`DAG::RuntimeSnapshot` is immutable and JSON-safe. It exposes current workflow,
revision, node, and attempt coordinates; canonical committed predecessor
`Success` snapshots for the current revision; and node-scoped effect snapshots.
It intentionally excludes dispatcher lease fields, storage timestamps,
unrelated node attempts, and consumer-owned runtime objects. See
`examples/runtime_snapshot.rb` for a runnable end-to-end example.

## Effect Intents

Steps describe side effects as abstract intents instead of performing
physical I/O. The kernel's public semantics are:

```text
exactly-once durable effect intent reservation
+ at-most-once successful effect recording per (type, key)
+ lease-protected dispatch
+ effectively-once external side effects through host handlers
```

`ruby-dag` guarantees the first three. Concrete handlers and exactly-once
protection against external systems (remote idempotency keys,
reconciliation, retry/backoff) live in the consumer host (`Delphi` is the
reference consumer; see `Delphi Ruby DAG Execution Plan.md`) — not in
`ruby-dag`.

`(type, key)` is the global semantic identity of an effect. Real keys must
namespace by workflow/revision/node so that two workflows or two revisions
never collide on a shared name; payload differences for the same `(type,
key)` are rejected with `DAG::Effects::IdempotencyConflictError`.

### Awaited abstract effect

A step returns `Waiting` with `proposed_effects` when it needs external
work. The runner reserves the intent atomically with the attempt commit;
on resume, the same step is re-invoked with a snapshot of the resolved
effect in `input.metadata[:effects]`. `DAG::Effects::Await` maps the
snapshot to `Waiting` / `Success` / `Failure`:

```ruby
class FetchStep < DAG::Step::Base
  def call(input)
    url = "https://example.com"
    intent = DAG::Effects::Intent[
      type: "http_get",
      key: [
        "wf:#{input.metadata.fetch(:workflow_id)}",
        "rev:#{input.metadata.fetch(:revision)}",
        "node:#{input.node_id}",
        "fetch"
      ].join(":"),
      payload: {"url" => url}
    ]

    DAG::Effects::Await.call(input, intent) do |result|
      # Yielded only when the effect has succeeded; result is the
      # JSON-safe value the handler returned.
      DAG::Success[value: result.fetch("body")]
    end
  end
end
```

### Detached effect

A step can also propose non-blocking effects on `Success` (e.g. metrics,
notifications, audit). The node commits without waiting for the effect to
complete:

```ruby
class NotifyStep < DAG::Step::Base
  def call(input)
    intent = DAG::Effects::Intent[
      type: "email",
      key: [
        "wf:#{input.metadata.fetch(:workflow_id)}",
        "rev:#{input.metadata.fetch(:revision)}",
        "node:#{input.node_id}",
        "welcome"
      ].join(":"),
      payload: {"to" => "user@example.com"}
    ]
    DAG::Success[value: :ok, proposed_effects: [intent]]
  end
end
```

### Handler failures

`DAG::Effects::Dispatcher` claims ready effects under a lease and calls
the consumer-provided handler for each effect type. Handlers receive a
`DAG::Effects::Record` and return a `DAG::Effects::HandlerResult`. The
retriable / terminal distinction lives entirely in the handler:

```ruby
class HttpHandler
  def call(record)
    response = HTTP.get(record.payload["url"])

    if response.status.success?
      DAG::Effects::HandlerResult.succeeded(result: response.parse)
    elsif response.status.server_error? || response.status.too_many_requests?
      # Retriable: dispatcher will reclaim after not_before_ms.
      DAG::Effects::HandlerResult.failed(
        error: {code: response.status.code},
        retriable: true,
        not_before_ms: (Time.now.to_f * 1000).to_i + 30_000
      )
    else
      # Terminal: the awaiting step will receive Failure on next resume.
      DAG::Effects::HandlerResult.failed(
        error: {code: response.status.code},
        retriable: false
      )
    end
  rescue => e
    # Raised exceptions become retriable failures with a JSON-safe error.
    DAG::Effects::HandlerResult.failed(
      error: {class: e.class.name, message: e.message},
      retriable: true
    )
  end
end
```

See `CONTRACT.md` for the full effect-aware kernel contract (storage,
dispatcher, lease semantics) and `Delphi Ruby DAG Execution Plan.md` §3
for the canonical intent-key shape and §6.3 for the handler failure
taxonomy used by Delphi.

## Architecture

- **Graph** (`DAG::Graph`) — pure DAG with deterministic topological
  order, cycle detection, descendant queries, canonical `to_h`.
- **Workflow Definition** (`DAG::Workflow::Definition`) — immutable,
  chainable, `revision`-aware. Fingerprintable via the fingerprint
  port.
- **Step types** — `DAG::StepProtocol` plus `DAG::Step::Base`. Built-ins:
  `:noop` and `:passthrough`. Custom step types register on a
  `DAG::StepTypeRegistry` with a deterministic
  `fingerprint_payload`.
- **Runner** (`DAG::Runner`) — frozen, dependency-injected. `#call(id)`
  starts pending workflows, `#resume(id)` recovers running/waiting/paused
  workflows, and `#retry_workflow(id)` enforces the workflow-retry budget.
- **Adapters** (`DAG::Adapters::*`) — `Memory::Storage`,
  `Memory::EventBus`, `Null::EventBus`, plus `Stdlib::{Clock,
  IdGenerator, Fingerprint, Serializer}`.

`dag/testing/storage_contract` exposes
`DAG::Testing::StorageContract::All`, a reusable G1-G13 behavioral suite for
adapters that implement `DAG::Ports::Storage`. This repository runs it against
`DAG::Adapters::Memory::Storage`; production adapters can include the same
suite without depending on memory-adapter internals. The suite asserts
receipt shapes for mutating storage operations and the public failure
vocabulary, so consumers branch on structured values and exception classes
instead of adapter-specific messages.

See `CONTRACT.md` for the closed event types, allowed transitions, and
boundary contract; `docs/plans/2026-04-26-r1-deterministic-kernel.md`
for the R1 implementation notes.

## Status

R0-R3 and the effect-aware kernel work have landed. The `1.0.0` release
gate is tracked in #74. S0 is the first SQLite storage adapter, but it
lives in the Delphi consumer (`nexus`, branch `delphi-v1`) and implements
this repo's public `DAG::Ports::Storage` contract.

Roadmap board: <https://github.com/users/duncanita/projects/2>.

## Contributing

```bash
bundle install
bundle exec rake          # tests + Standard + custom DAG cops
```

The default rake task runs Minitest, Standard, and the four custom
`DAG/*` RuboCop cops (`NoThreadOrRactor`, `NoMutableAccessors`,
`NoInPlaceMutation`, `NoExternalRequires`).

## Production readiness stress

```bash
scripts/production_readiness.rb --fast
scripts/production_readiness.rb
```

`--fast` targets about two minutes. Without `--fast`, the script runs a
one-hour stress profile. Use `--duration SECONDS` and `--seed INTEGER` to
reproduce or shorten a run.

License: MIT.
