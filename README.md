# ruby-dag

Deterministic DAG execution kernel for Roadmap v3.4. Zero runtime
dependencies; Ruby 3.4+.

> The legacy v0.x runtime (`Workflow::Runner`, YAML loader, parallel
> strategies, `:exec` / `:ruby_script` / `:sub_workflow` step types) was
> removed during R1. The current state of the kernel is the deterministic
> in-memory runtime described below. Durable in-memory resume and adaptive
> structural mutation are present; SQLite storage arrives in S0.

## Quick start

```ruby
require "ruby-dag"

storage     = DAG::Adapters::Memory::Storage.new
event_bus   = DAG::Adapters::Memory::EventBus.new
clock       = DAG::Adapters::Stdlib::Clock.new
id_gen      = DAG::Adapters::Stdlib::IdGenerator.new
fingerprint = DAG::Adapters::Stdlib::Fingerprint.new
serializer  = DAG::Adapters::Stdlib::Serializer.new

registry = DAG::StepTypeRegistry.new
registry.register(name: :passthrough,
                  klass: DAG::BuiltinSteps::Passthrough,
                  fingerprint_payload: { v: 1 })
registry.freeze!

definition = DAG::Workflow::Definition.new
  .add_node(:a, type: :passthrough)
  .add_node(:b, type: :passthrough)
  .add_node(:c, type: :passthrough)
  .add_edge(:a, :b)
  .add_edge(:b, :c)

workflow_id = id_gen.call
storage.create_workflow(
  id: workflow_id,
  initial_definition: definition,
  initial_context: { hello: "world" },
  runtime_profile: DAG::RuntimeProfile.default
)

runner = DAG::Runner.new(
  storage: storage, event_bus: event_bus, registry: registry,
  clock: clock, id_generator: id_gen,
  fingerprint: fingerprint, serializer: serializer
)

result = runner.call(workflow_id)
result.state
# => :completed
```

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

See `CONTRACT.md` for the closed event types, allowed transitions, and
boundary contract; `docs/plans/2026-04-26-r1-deterministic-kernel.md`
for the R1 implementation notes.

## Status

R0-R3 have landed. Next: S0 SQLite storage and the Release v1.0 readiness
gate (#74).

Roadmap board: <https://github.com/users/duncanita/projects/2>.

## Contributing

```bash
bundle install
bundle exec rake          # test + standardrb
```

License: MIT.
