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

`DAG::Toolkit.in_memory_kit` is a convenience for examples and tests; production
callers construct the seven `DAG::Runner` ports explicitly so production-grade
adapters can be injected.

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

R0-R3 have landed. The `1.0.0` release gate is tracked in #74; `S0`
introduces the SQLite storage adapter once the gate closes.

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
