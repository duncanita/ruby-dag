# ruby-dag

Lightweight DAG workflow runner in pure Ruby. Zero runtime dependencies.

Define multi-step workflows as YAML or build them programmatically. Automatic dependency resolution and parallel execution via a pluggable Strategy (Threads, Processes, or Sequential).

**Version:** 0.4.0 | **License:** MIT | **Ruby:** >= 3.2

## Install

```bash
git clone git@github.com:duncanita/ruby-dag.git
cd ruby-dag
bundle install
```

## Architecture

Two layers, loosely coupled:

- **Graph** (`DAG::Graph`) -- pure DAG data structure. Nodes are symbols, edges carry optional metadata. Enforces acyclicity. Iteration is via `each_node` / `each_edge` only — `Graph` intentionally does **not** include `Enumerable`, so `graph.map` / `graph.count` / `graph.include?` do not exist. Call `graph.each_node.map { ... }` / `graph.each_edge.count` / `graph.node?(name)` instead. No workflow concepts.
- **Workflow** (`DAG::Workflow::*`) -- steps, types, YAML loading/dumping, and a pluggable `Parallel::Strategy` hierarchy (`Sequential`, `Threads`, `Processes`). The `Runner` is a thin coordinator: it builds Tasks per topological layer and delegates execution to the configured strategy. Built on top of Graph.

You can use the Graph layer alone if you just need a DAG.

## Quick Start

### CLI

```bash
bin/dag examples/deploy.yml              # run a workflow
bin/dag examples/deploy.yml --dry-run    # show execution plan
bin/dag examples/deploy.yml --verbose    # verbose output
bin/dag examples/deploy.yml --no-parallel # disable parallel execution
```

### YAML Workflow

```yaml
name: deploy
nodes:
  test:
    type: exec
    command: "bundle exec rake test"
    timeout: 120

  build:
    type: exec
    command: "docker build -t app ."
    depends_on: [test]
    timeout: 300

  push:
    type: exec
    command: "docker push app:latest"
    depends_on: [build]

  notify:
    type: exec
    command: "echo 'Deployed!'"
    depends_on: [push]
```

### YAML schema

The YAML loader uses `YAML.safe_load` and accepts only **string keys**,
scalar values (strings, integers, floats, booleans, arrays, hashes), and
**Ruby Symbols** so step configs that use symbol values (e.g. `mode: :w`)
round-trip cleanly through `Dumper`. It does **not** deserialize Procs,
Time, Date, or arbitrary Ruby objects — those are not safe to load from
untrusted YAML.

| Key | Where | Type | Required | Notes |
|---|---|---|---|---|
| `nodes` | top level | mapping | yes | the only top-level key the loader reads |
| `<node-name>` | under `nodes` | mapping | yes | becomes the symbol node name in the graph |
| `type` | under each node | string | yes | must be a registered, YAML-safe step type (`exec`, `ruby_script`, `file_read`, `file_write`, plus any custom types registered with `yaml_safe: true`) |
| `depends_on` | under each node | array | no | each entry is either a string (the upstream node name) or a mapping with `from:` plus optional metadata such as `as:` and `version:` (`:latest`, positive Integer, or `:all`) |
| `run_if` | under each node | mapping | no | declarative condition DSL using `all` / `any` / `not` and leaf predicates on direct dependencies |
| any other key | under each node | scalar / array / mapping | no | passed verbatim into the step's `config` (e.g. `command`, `path`, `timeout`, `mode`, `from`, `content`) |

The `:ruby` step type is **not** YAML-safe — its `callable` is a Proc that
cannot live in YAML. Build those programmatically with `Loader.from_hash` or
`Step.new` directly.

Programmatic workflows can still use a callable `run_if`, but YAML workflows
must use the declarative DSL. For Ruby APIs, `run_if: nil` is treated the same
as omitting the condition entirely; blank YAML `run_if:` remains invalid.

```yaml
nodes:
  decide:
    type: exec
    command: "echo prod"

  deploy_prod:
    type: exec
    command: "./deploy prod"
    depends_on:
      - decide
    run_if:
      from: decide
      value:
        equals: "prod"

  deploy_staging:
    type: exec
    command: "./deploy staging"
    depends_on:
      - decide
    run_if:
      from: decide
      value:
        equals: "staging"
```

### Load and Run

```ruby
require_relative "lib/dag"

definition = DAG::Workflow::Loader.from_file("deploy.yml")
runner = DAG::Workflow::Runner.new(definition)
result = runner.call

if result.success?
  puts "Done! Steps: #{result.outputs.keys}, Trace: #{result.trace.size} entries"
else
  puts "Failed at #{result.error[:failed_node]}: #{result.error[:step_error]}"
end
```

`Runner#call` returns a `DAG::Workflow::RunResult`, not a workflow-level
`DAG::Success` / `DAG::Failure`. The step-level monad is still used inside
`result.outputs`, but the workflow result itself exposes:

- `result.status` — `:completed`, `:failed`, `:waiting`, or `:paused`
- `result.success?` / `result.failure?`
- `result.outputs` — completed or intentionally skipped step results keyed by node name
- `result.trace` — append-only attempt trace
- `result.error` — `nil` on success, `{failed_node:, step_error:}` on failure
- `result.workflow_id` — `nil` for in-memory runs unless you set one explicitly

### Step Middleware, Structured Logging, and Events

Middleware wraps a single step attempt and is configured per runner via `middleware:`.
Attempt-local middleware can observe step execution without changing admission,
waiting, or persistence semantics.

```ruby
require "json"
require_relative "lib/dag"

logged_events = []
logger = lambda do |event|
  logged_events << event
  puts JSON.generate(event.transform_keys(&:to_s))
end

runner = DAG::Workflow::Runner.new(definition,
  parallel: false,
  workflow_id: "demo-logging",
  middleware: [DAG::Workflow::LoggingMiddleware.new(logger: logger)])

result = runner.call
puts DAG::Workflow::LoggingMiddleware.format(logged_events.last)
```

Structured events include stable fields such as:
- `event` (`:starting`, `:finished`, `:raised`)
- `step_name`, `step_type`
- `workflow_id`, `node_path`, `attempt`, `depth`, `parallel`
- `input_keys` for start events
- `status` for finish events
- `error_class` and `error_message` for raised events

See `examples/logging_middleware.rb` for a successful end-to-end example and
`examples/logging_middleware_failures.rb` for both failure-result logging and a true
`raised` event produced by an inner middleware exception.

For event emission, configure `EventMiddleware` with an `EventBus` implementation:

```ruby
class MemoryEventBus < DAG::Workflow::EventBus
  attr_reader :events

  def initialize
    @events = []
  end

  def publish(event)
    @events << event
  end
end

bus = MemoryEventBus.new
runner = DAG::Workflow::Runner.new(definition,
  event_bus: bus,
  middleware: [DAG::Workflow::EventMiddleware.new])
```

`EventMiddleware` emits `DAG::Workflow::Event` objects only for successful final attempts.
Each event includes `name`, `workflow_id`, `node_path`, `payload`, `metadata`, and `emitted_at`.
The recommended wiring is `event_bus:` on `Runner`, with `EventMiddleware` reading the bus from `execution.event_bus`; you can still inject a bus directly into the middleware when you need a one-off override.
`emit_events:` must be an array of descriptors shaped like `{name: :event_name, if: ->(result) { ... }, payload: ->(result) { ... }, metadata: ->(result) { ... }}` where `name` is required and `if` / `payload` / `metadata` are optional but must be callable when present. When `payload` is omitted the event uses `result.value`; a payload callable may return `nil`. When `metadata` is omitted the event uses `{}`; metadata returning `nil` is normalized to `{}`.
See `examples/event_middleware.rb` for a flat runnable example and `examples/nested_event_middleware.rb` for namespaced events emitted from child steps inside a sub-workflow.

### Build Programmatically and Dump to YAML

```ruby
require_relative "lib/dag"

graph = DAG::Graph.new
graph.add_node(:fetch)
graph.add_node(:transform)
graph.add_node(:save)
graph.add_edge(:fetch, :transform)
graph.add_edge(:transform, :save)

registry = DAG::Workflow::Registry.new
registry.register(DAG::Workflow::Step.new(name: :fetch, type: :exec, command: "curl -s https://api.example.com/data"))
registry.register(DAG::Workflow::Step.new(name: :transform, type: :exec, command: "jq '.results'"))
registry.register(DAG::Workflow::Step.new(name: :save, type: :file_write, path: "output.json"))

definition = DAG::Workflow::Definition.new(graph: graph, registry: registry)

# Serialize to YAML
yaml_string = DAG::Workflow::Dumper.to_yaml(definition)
DAG::Workflow::Dumper.to_file(definition, "workflow.yml")

# Round-trips: Loader.from_yaml(Dumper.to_yaml(def)) == def
```

### Build with `from_hash`

```ruby
require_relative "lib/dag"

definition = DAG::Workflow::Loader.from_hash(
  fetch:     { type: :exec, command: "curl -s https://api.example.com/data" },
  transform: { type: :exec, command: "jq '.results'", depends_on: [:fetch], timeout: 30 },
  save:      { type: :file_write, path: "output.json", depends_on: [:transform] }
)

result = DAG::Workflow::Runner.new(definition.graph, definition.registry).call
```

Retry configuration is validated when the workflow is built: `max_attempts` must be an integer >= 1, `backoff` must be one of `fixed`, `linear`, or `exponential`, delays must be numeric and >= 0, `max_delay` must not be smaller than `base_delay`, and `retry_on` must be an array of symbol-like error codes.

### Checkpointing and Resume

For durable execution, pass both a `workflow_id` and an `execution_store`.
The smallest built-in store today is the in-memory `MemoryStore`, which is good
for tests and runnable examples.

```ruby
require_relative "lib/dag"

store = DAG::Workflow::ExecutionStore::MemoryStore.new
fetch_calls = 0

definition = DAG::Workflow::Loader.from_hash(
  fetch: {
    type: :ruby,
    resume_key: "fetch-v1",
    callable: ->(_input) do
      fetch_calls += 1
      DAG::Success.new(value: "payload-#{fetch_calls}")
    end
  },
  transform: {
    type: :ruby,
    depends_on: [:fetch],
    resume_key: "transform-v1",
    callable: ->(input) { DAG::Success.new(value: input[:fetch].upcase) }
  }
)

runner = -> {
  DAG::Workflow::Runner.new(definition,
    parallel: false,
    workflow_id: "demo-run",
    execution_store: store)
}

first = runner.call.call
second = runner.call.call

puts first.outputs[:transform].value   # => "PAYLOAD-1"
puts second.outputs[:transform].value  # => "PAYLOAD-1"
puts fetch_calls                       # => 1 (the second run reused the stored output)
```

Notes:
- durable execution currently requires `workflow_id:`
- `:ruby` steps must declare a deterministic `resume_key:` when durable execution is enabled
- changing the workflow fingerprint for an existing `workflow_id` raises `DAG::ValidationError` before any step runs
- see `examples/checkpoint_resume.rb` for a runnable end-to-end example that is exercised in the test suite

### Versioned dependency inputs

Versioned outputs are stored per node as monotonically increasing successful
versions starting at `1`. A downstream dependency can request:
- the default latest value
- a specific historical version
- all successful versions in ascending order

```ruby
workflow = DAG::Workflow::Loader.from_hash(
  source: {
    type: :ruby,
    resume_key: "source-v1",
    schedule: {ttl: 1},
    callable: ->(_input) { DAG::Success.new(value: "...") }
  },
  history_consumer: {
    type: :ruby,
    depends_on: [{from: :source, version: :all, as: :history}],
    resume_key: "history-consumer-v1",
    callable: ->(input) { DAG::Success.new(value: input[:history]) }
  },
  first_consumer: {
    type: :ruby,
    depends_on: [{from: :source, version: 1, as: :first_value}],
    resume_key: "first-consumer-v1",
    callable: ->(input) { DAG::Success.new(value: input[:first_value]) }
  }
)
```

Notes:
- successful outputs now get monotonic per-node versions instead of reusing the retry attempt number
- `depends_on` metadata supports `as:` to rename the local input key
- `version: :all` resolves to an array of raw values ordered by ascending version
- missing local historical versions fail explicitly with `code: :missing_dependency_version`
- cross-workflow descriptors use `workflow:` plus `node:` instead of `from:` and resolve through `cross_workflow_resolver:`
- the `cross_workflow_resolver:` callable is invoked with three values — `workflow_id`, `node_name`, `version` — as either positional args or keyword args, auto-detected from the callable's `parameters`. It returns the raw value, a `DAG::Success`, a `{result: DAG::Success(...)}` hash (store-entry shape), or `nil` to signal "not yet available"
- when a cross-workflow requested version is unavailable, the node becomes waiting so a later invocation can satisfy it
- resolver exceptions fail explicitly with `code: :cross_workflow_resolution_failed`
- versioned dependency inputs require durable execution (`execution_store:` plus `workflow_id:`); cross-workflow ones additionally require `cross_workflow_resolver:`
- loader/dumper round-trip `version:` and `as:` metadata for both local and cross-workflow dependencies
- see `examples/versioned_dependency_inputs.rb` and `examples/missing_requested_version_waiting.rb` for runnable examples exercised in the test suite

### Invalidation cascade

Invalidation marks previously completed reusable outputs as stale so the next run
recomputes that branch from the current definition.

```ruby
store = DAG::Workflow::ExecutionStore::MemoryStore.new

invalidated = DAG::Workflow.invalidate(
  workflow_id: "demo-invalidation",
  node: [:source],
  definition: workflow,
  execution_store: store,
  max_cascade_depth: nil,
  cause: DAG::Workflow.upstream_change_cause(source: :coordinator)
)

stale = DAG::Workflow.stale_nodes(
  workflow_id: "demo-invalidation",
  execution_store: store
)
```

Notes:
- `invalidate` walks the transitive descendant closure in the current definition starting from the supplied `node_path`
- the `node:` argument accepts both top-level paths like `[:source]` and nested paths like `[:process, :transform]` for sub-workflow descendants
- only nodes currently marked `:completed` are transitioned to `:stale`
- nested invalidation also marks completed ancestor `:sub_workflow` nodes stale so parent reusable outputs do not hide child recomputation on the next run
- use `DAG::Workflow.manual_invalidation_cause(...)` and `DAG::Workflow.upstream_change_cause(...)` as convenient standard helpers for the most common cause payloads; the runnable examples show both helper styles across top-level and nested invalidation flows
- `cause:` still accepts any Hash merged into the stored stale cause; `invalidated_from` is always preserved, cannot be overridden, and `code` defaults to `:manual_invalidation`
- `stale_nodes` returns normalized node paths sorted for stable inspection
- stale nodes supersede their reusable outputs, but `version: :all` keeps the historical audit trail intact
- the next runner invocation recomputes stale branches because `load_output(..., version: :latest)` ignores superseded outputs
- `max_cascade_depth:` limits how far descendants are traversed from the invalidated root
- see `examples/invalidation_cascade.rb`, `examples/nested_invalidation_cascade.rb`, and `examples/yaml_nested_invalidation_cascade.rb` for runnable end-to-end examples exercised in the test suite

### Dynamic graph mutation impact

Subtree replacement is a between-invocations operation: first derive a new
workflow definition with `replace_subtree`, then inspect/apply the persisted
state impact for the branch being replaced.

```ruby
impact = DAG::Workflow.subtree_replacement_impact(
  workflow_id: "demo-mutation",
  definition: workflow,
  root_node: :process,
  execution_store: store
)

DAG::Workflow.apply_subtree_replacement_impact(
  workflow_id: "demo-mutation",
  definition: workflow,
  root_node: :process,
  execution_store: store,
  cause: {source: :planner},
  new_definition: mutated_workflow
)
```

Notes:
- `subtree_replacement_impact` is read-only and returns `{obsolete_nodes:, stale_nodes:}`
- the replaced root is included in `obsolete_nodes` only when it is currently `:completed`
- completed downstream descendants reachable from the replaced root are included in `stale_nodes`
- `apply_subtree_replacement_impact` marks obsolete roots with `obsolete_cause` and stale descendants with `stale_cause`
- pass `new_definition:` when you want the persisted run fingerprint and known node paths updated for the next runner invocation against the mutated workflow
- both helpers preserve audit history by superseding reusable outputs instead of deleting historical versions
- the replaced root cannot currently be `:running`; mutation is only legal between runner invocations
- `cause:` accepts any Hash merged into the stored transition cause, but `replaced_from` is reserved and always set from `root_node`
- see `examples/immutable_subtree_replacement.rb` for definition mutation, `examples/subtree_replacement_impact.rb` for persisted-state impact planning/application, and `examples/subtree_replacement_file_store.rb` for the same rerun flow across fresh `FileStore` instances

### Waiting and not_before scheduling

Scheduling is eligibility-based. The runner does not sleep: if a node has a
future `schedule[:not_before]`, it becomes waiting and the run returns
`status: :waiting` once no runnable work remains.

```ruby
clock = Struct.new(:wall_time, :mono_time) do
  def wall_now = wall_time
  def monotonic_now = mono_time
  def advance(seconds) = self.wall_time += seconds
end.new(Time.utc(2026, 4, 15, 9, 0, 0), 0.0)

store = DAG::Workflow::ExecutionStore::MemoryStore.new
result = DAG::Workflow::Runner.new(definition,
  parallel: false,
  clock: clock,
  workflow_id: "demo-waiting",
  execution_store: store).call

clock.advance(3600)
result = DAG::Workflow::Runner.new(definition,
  parallel: false,
  clock: clock,
  workflow_id: "demo-waiting",
  execution_store: store).call
```

Notes:
- `schedule[:not_before]` uses `clock.wall_now`
- `schedule[:not_after]` fails the step with `code: :deadline_exceeded` before late work starts
- `schedule[:ttl]` expires reusable outputs relative to `clock.wall_now`, marks them stale with `code: :ttl_expired`, and causes re-execution instead of reuse
- YAML Loader/Dumper round-trip `schedule.not_before`, `schedule.not_after`, `schedule.ttl`, and `schedule.cron` with YAML-safe scalar values
- waiting nodes do not emit `Success(nil)` outputs
- waiting nodes do not block independent branches that are still runnable later in the same invocation
- waiting runs persist `workflow_status: :waiting` plus `waiting_nodes` in the execution store
- see `examples/waiting_not_before.rb`, `examples/not_after_deadline.rb`, `examples/schedule_metadata_roundtrip.rb`, and `examples/ttl_expiry.rb` for runnable examples exercised in the test suite

### Pause and resume

Pause is coordinator-driven through the execution store. The runner checks the
pause flag between layers, never in the middle of a running layer.

```ruby
store = DAG::Workflow::ExecutionStore::MemoryStore.new

first = DAG::Workflow::Runner.new(definition,
  parallel: false,
  workflow_id: "demo-pause",
  execution_store: store,
  on_step_finish: lambda do |name, _result|
    store.set_pause_flag(workflow_id: "demo-pause", paused: true) if name == :fetch
  end).call

store.set_pause_flag(workflow_id: "demo-pause", paused: false)
second = DAG::Workflow::Runner.new(definition,
  parallel: false,
  workflow_id: "demo-pause",
  execution_store: store).call

puts first.status   # => :paused
puts second.status  # => :completed
```

Notes:
- pause is observed before the next layer starts
- completed reusable outputs are reused after resume
- paused runs persist `workflow_status: :paused` in the execution store
- see `examples/pause_resume.rb` for a runnable end-to-end example exercised in the test suite

### Sub-workflow composition

A step can run a nested workflow with type `:sub_workflow`. The child can come
from either a programmatic `definition:` or a YAML-safe `definition_path:`.
The child run inherits the parent runner's parallel mode, middleware, context,
remaining timeout budget, workflow ID, and execution store.

Programmatic form:

```ruby
child = DAG::Workflow::Loader.from_hash(
  analyze: {
    type: :ruby,
    callable: ->(input) { DAG::Success.new(value: input[:raw].upcase) }
  },
  summarize: {
    type: :ruby,
    depends_on: [:analyze],
    callable: ->(input, context) { DAG::Success.new(value: "#{input[:analyze]}#{context[:suffix]}") }
  }
)

parent = DAG::Workflow::Loader.from_hash(
  fetch: {
    type: :ruby,
    callable: ->(_input) { DAG::Success.new(value: "hello") }
  },
  process: {
    type: :sub_workflow,
    definition: child,
    depends_on: [:fetch],
    input_mapping: {fetch: :raw},
    output_key: :summarize
  }
)

result = DAG::Workflow::Runner.new(parent,
  parallel: false,
  context: {suffix: "!"}).call

puts result.outputs[:process].value  # => "HELLO!"
puts result.trace.map(&:name)        # => [:fetch, :"process.analyze", :"process.summarize", :process]
```

YAML-safe form:

```yaml
nodes:
  process:
    type: sub_workflow
    definition_path: sub_workflows/child.yml
    output_key: nested
    resume_key: process-v1
```

`definition_path:` is resolved relative to the YAML file that declares it, so a
child workflow can itself use relative `definition_path:` entries for deeper
nesting.

Notes:
- `:sub_workflow` must declare exactly one of `definition:` or `definition_path:`
- child trace entries are flattened into the parent trace with names like `:"process.summarize"`
- default sub-workflow output is a hash of child leaf values; `output_key:` selects one leaf
- if the child run returns `:waiting` or `:paused`, the parent run propagates that workflow status and the parent step does not emit an output
- durable child outputs are stored under the parent node path, e.g. `[:process, :summarize]`
- the dumper emits YAML-safe sub-workflows when they use `definition_path:` and rejects programmatic `definition:` children
- see `examples/sub_workflow.rb` and `examples/sub_workflow_parent.yml` for runnable examples exercised in the test suite

## Graph API

Pure DAG with no workflow awareness. The ONLY iteration entry points are
`each_node` and `each_edge`. `Graph` does not include `Enumerable` and has no
top-level `each`, on purpose — `graph.map` / `graph.count` / `graph.include?`
would all be ambiguous between nodes and edges. Use the explicit form instead
(both `each_node` and `each_edge` return an `Enumerator` when called without a
block, so you get the full `Enumerable` surface by chaining):

```ruby
graph.each_node.map { |n| n.upcase }
graph.each_node.select { |n| graph.indegree(n) == 0 }
graph.each_edge.count
graph.node?(:a)        # membership
```

```ruby
# Build mutable
graph = DAG::Graph.new
graph.add_node(:a)
graph.add_node(:b)
graph.add_edge(:a, :b)
graph.freeze  # caches topological_layers, roots, leaves

# Or use the Builder
graph = DAG::Graph::Builder.build do |b|
  b.add_node(:a)
  b.add_node(:b)
  b.add_edge(:a, :b)
end  # => frozen

# Immutable builders (return new frozen graphs)
graph2 = graph.with_node(:c).with_edge(:b, :c)
graph3 = graph2.without_node(:c)   # removes node and its edges
graph4 = graph2.without_edge(:b, :c) # removes edge, keeps both nodes
```

### Mutable Removal

```ruby
graph = DAG::Graph.new.add_node(:a).add_node(:b).add_edge(:a, :b)
graph.remove_edge(:a, :b)  # removes edge, keeps nodes
graph.remove_node(:b)      # removes node and all incident edges
```

### Queries

```ruby
graph.node_count         # => 3   (preferred when you mean "number of nodes")
graph.edge_count         # => 2   (preferred when you mean "number of edges")
graph.size               # => 3   (alias for node_count)
graph.empty?             # => false
graph.node?(:a)          # => true
graph.edge?(:a, :b)      # => true
graph.nodes              # => Set[:a, :b, :c]
graph.edges              # => Set[Edge(a -> b), ...]  (lazy, computed on each call)
graph.incoming_edges(:c) # => Set[Edge(b -> c)]
graph.successors(:a)     # => Set[:b]
graph.predecessors(:b)   # => Set[:a]
graph.ancestors(:c)      # => Set[:a, :b]
graph.descendants(:a)    # => Set[:b, :c]
graph.roots              # => Set[:a]      (cached, frozen, if frozen)
graph.leaves             # => Set[:c]      (cached, frozen, if frozen)
graph.path?(:a, :c)      # => true
graph.indegree(:b)       # => 1
graph.outdegree(:a)      # => 1
graph.subgraph([:a, :b]) # => new Graph with only those nodes

# Iteration
graph.each_node { |n| ... }
graph.each_edge { |e| puts "#{e.from} -> #{e.to}" }
graph.each_root { |r| ... }      # iterator over roots (insertion order)
graph.each_leaf { |l| ... }

# Enumerable surface is available via each_node / each_edge explicitly:
graph.each_node.map { |n| n.upcase }
graph.each_node.select { |n| graph.indegree(n) == 0 }
graph.each_node.count    # => 3  (same as graph.node_count)
graph.node?(:a)          # => true  (membership)

# Serialization
graph.to_h               # => {nodes: [:a, :b, :c], edges: [{from: :a, to: :b}, ...]}
graph.to_dot             # => "digraph dag {\n  a;\n  b;\n  a -> b;\n}"
graph.to_dot(name: "my_dag")
```

Node names that aren't bare `[A-Za-z_][A-Za-z0-9_]*` identifiers are quoted
and escaped in the DOT output, so symbols like `:"my-node"` or `:'1st'`
produce valid DOT that `dot(1)` can parse.

### Topological Sort

```ruby
graph.topological_layers # => [[:a], [:b], [:c]]  -- parallel layers (cached if frozen)
graph.topological_sort   # => [:a, :b, :c]        -- flat order
```

### Edge Metadata

Edges carry optional metadata (default `{}`). Useful for weighted path analysis.

```ruby
graph.add_edge(:a, :b, weight: 5, label: "critical")
graph.edge_metadata(:a, :b)  # => {weight: 5, label: "critical"}

edge = graph.edges.first
edge.metadata  # => {weight: 5, label: "critical"}
edge.weight    # => 5  (convenience, defaults to 1)
```

In YAML, use expanded `depends_on` for metadata:

```yaml
nodes:
  parse:
    type: exec
    command: "parse data"
    depends_on:
      - from: fetch
        weight: 3
```

### Path Analysis

All path algorithms are O(V+E) using a single topological pass with edge weights.

```ruby
graph.shortest_path(:a, :d) # => {cost: 2, path: [:a, :b, :d]} or nil
graph.longest_path(:a, :d)  # => {cost: 11, path: [:a, :c, :d]} or nil
graph.critical_path         # => {cost: 8, path: [:a, :b, :d]}  (longest root-to-leaf)
```

### Validation

Cycle detection already runs at edge-insertion time — the validator does not
repeat it. The default built-in rule is `:no_isolated` (multi-node graphs
must not contain any node without at least one incident edge). It runs by
default; opt out with `defaults: []`.

```ruby
result = DAG::Graph::Validator.validate(graph) do |v|
  v.rule("must have a single root") { |g| g.roots.size == 1 }
end

result.valid?  # => true/false
result.errors  # => ["must have a single root", "Node c is isolated (no edges)"]

# Skip the built-in rules entirely, run only custom ones:
DAG::Graph::Validator.validate(graph, defaults: []) do |v|
  v.rule("must have a single root") { |g| g.roots.size == 1 }
end

# Raise on failure:
DAG::Graph::Validator.validate!(graph)
```

Available built-in rules: `:no_isolated` (default).

## Step Types

### Core Types

| Type | Purpose | Required Config | YAML-safe |
|------|---------|----------------|-----------|
| `exec` | Run a shell command | `command` | yes |
| `ruby_script` | Run a Ruby script file | `path` | yes |
| `file_read` | Read a file | `path` | yes |
| `file_write` | Write a file | `path` (+ `content` or `from` for multi-dep) | yes |
| `ruby` | Execute a lambda/proc | `callable` | no |

### `file_write` content resolution

`file_write` picks what to write in this order:

1. `content:` config (literal value) — always wins.
2. `from:` config (Symbol) — selects which upstream dep's value to write.
3. Single upstream dep — uses its value automatically.
4. Zero or multiple upstream deps with no `:content` or `:from` — returns
   `Failure`. (Previously this silently wrote `Hash#to_s`. It does not anymore.)

```ruby
# Multi-dep: must specify :from or :content
DAG::Workflow::Step.new(name: :write, type: :file_write, path: "out.txt", from: :transform)
```

### Custom Step Types

Register custom step types via the plugin registry:

```ruby
DAG::Workflow::Steps.register(:my_type, MyStepClass, yaml_safe: true)
DAG::Workflow::Steps.freeze_registry!  # optional: lock the registry after all custom types are registered
```

`freeze_registry!` is an opt-in lock — call it once you've registered every
custom type your application needs. Subsequent `register` calls then raise. The
library never calls it for you, so you can keep registering throughout the
process lifetime if you'd rather.

## Parallel Execution

Steps in the same topological layer run in parallel. The runner uses a
**Strategy** pattern with three pluggable modes — pick one with the `parallel:`
keyword on `Runner.new`.

| `parallel:` value | Strategy class | Default? | Hard concurrency cap | Step constraints |
|---|---|---|---|---|
| `true` / `:threads` | `Parallel::Threads` | yes | yes (`max_parallelism`) | none |
| `false` / `:sequential` | `Parallel::Sequential` | — | n/a (always 1) | none |
| `:processes` | `Parallel::Processes` | — | yes (`max_parallelism`) | result must be Marshal-able |

`max_parallelism:` defaults to `[Etc.nprocessors, 8].min`.

```ruby
DAG::Workflow::Runner.new(graph, registry,
  parallel: :threads,
  max_parallelism: 4
).call
```

### Threads (default)

The right choice for the dominant ruby-dag workload — `exec`, `ruby_script`,
`file_read`, `file_write` all release the GVL during their syscalls, so threads
get real concurrency for them. Threads share memory, so step results can be
any Ruby object (no shareability or marshaling constraint).

CPU-bound pure-Ruby work in a `:ruby` step still serializes through the GVL.
For that case, prefer `:processes`.

### Processes

Forks one child per task and ships the result back through a pipe via Marshal.
Windowed at `max_parallelism`. Use this when:

- A step might crash the interpreter (segfault, OOM) and you want isolation.
- You need true parallelism for CPU-bound pure-Ruby work (bypasses the GVL).

Constraints:
- Step results must be Marshal-able. Procs, lambdas, IO objects, and anonymous
  classes are not. Steps that return such values surface as a clean Failure
  with a "non-marshalable value" message.
- Not available on Windows (requires `Process.fork`).
- Result payloads should fit comfortably in one pipe buffer (~64 KB) to avoid
  the child blocking on write.

### Step result constraints by strategy

| Strategy | Result constraint |
|---|---|
| `:sequential`, `:threads` | None — any Ruby object |
| `:processes` | Must be Marshal-able. Payload is drained incrementally with `read_nonblock` inside an `IO.select` loop, so children writing more than one pipe buffer (~64 KB) do not deadlock. |

## Conditional Execution

Steps can have a `run_if` condition. When the condition returns false, the step is skipped with `Success(nil)` output and `:skipped` trace status.

```ruby
DAG::Workflow::Step.new(
  name: :deploy,
  type: :exec,
  command: "deploy.sh",
  run_if: ->(inputs) { inputs[:test]&.include?("PASS") }
)
```

YAML workflows use a declarative `run_if` DSL instead of a Proc:

```yaml
run_if:
  all:
    - from: tests
      status: success
    - from: decide
      value:
        equals: "prod"
```

Supported combinators are `all`, `any`, and `not`. Leaf predicates may only
reference direct dependencies and can inspect:

- `status`: `success` or `skipped`
- `value.equals`
- `value.in`
- `value.present`
- `value.nil`
- `value.matches`

Downstream steps receive `nil` for skipped dependencies.

If the workflow finishes with no successful leaf nodes, the runner returns a
structured failure with code `:workflow_dead_end`. In practice this means a
branching workflow should model an explicit fallback or no-op leaf if "no
branch selected" is a valid outcome.

## Dependencies

Nodes declare dependencies with `depends_on`. The runner:

1. Computes execution layers via Kahn's topological sort (O(V+E))
2. For each layer, checks `run_if` and records `:skipped` trace entries for filtered steps
3. Builds `Parallel::Task`s for the runnable steps and hands them to the configured Strategy
4. Receives results from the Strategy in completion order, builds trace entries, fires `on_step_finish` callbacks
5. Stops the workflow on the first failure
6. Fails with `:workflow_dead_end` if every leaf node ends up skipped
7. Returns a single `{outputs:, trace:, error:}` payload (wrapped in `Success` or `Failure`)

Step inputs are **always** hashes keyed by dependency step name (e.g., `{ fetch: "data" }`). Zero-dependency steps receive `{}`.

## Execution Contract

- Step inputs are always hashes keyed by dependency step name. Zero-dependency steps receive `{}`.
- Step output constraints depend on which Strategy you pick (see [Step result constraints by strategy](#step-result-constraints-by-strategy)). Default `:threads` has none; `:processes` requires Marshal-able results.
- Callback ordering is per-step but not globally deterministic across nodes in the same parallel layer. `on_step_start` fires when the runner submits a step to the strategy (before actual execution begins); every started step gets a matching `on_step_finish`.
- For parent `:sub_workflow` steps that propagate child `:waiting` or `:paused`, `on_step_finish` receives `Success(nil)`. This is observational only: the parent step still emits no parent output and no parent trace entry for that invocation.
- On first step failure the workflow halts. Already-completed outputs from earlier layers (and from sibling steps in the same layer that finished before the failure was observed) are still returned.
- The runner returns `DAG::Workflow::RunResult`, so outputs and trace always live directly on `result.outputs` and `result.trace`. Failure details, when present, live in `result.error` as `{failed_node:, step_error:}`.
- Trace entries are `TraceEntry` records with `:name`, `:layer`, `:started_at`, `:finished_at`, `:duration_ms`, `:status` (`:success`, `:failure`, or `:skipped`), `:input_keys`, `:attempt`, and `:retried`. Skipped steps record `nil` timestamps and `0` duration.

## Error Handling

All errors inherit from `DAG::Error < StandardError`:

| Error | When raised |
|-------|-------------|
| `CycleError` | `add_edge` would create a cycle |
| `DuplicateNodeError` | `add_node` with an existing name |
| `UnknownNodeError` | Reference to a non-existent node or edge |
| `ValidationError` | Structural validation failure (has `.errors` array) |
| `SerializationError` | `Dumper` encounters a non-serializable step (`:ruby`) |

```ruby
rescue DAG::Error => e      # catches all DAG errors
rescue DAG::CycleError => e # catches only cycle errors
```

Adding a duplicate edge is **not** an error — it is a no-op (`add_edge` returns
`self` without changes if the edge already exists). Step-level failures from
the runner come back as `Failure` results rather than raised exceptions.

## Result Monad

Every step returns a `DAG::Success(value:)` or `DAG::Failure(error:)`. Both
include the `DAG::Result` marker module and expose the same API — methods on
one branch pass through untouched on the other.

```ruby
DAG::Success.new(value: 10)
  .and_then { |v| DAG::Success.new(value: v * 2) }                 # => Success(20)
  .and_then { |v| v > 100 ? DAG::Failure.new(error: "too big") : DAG::Success.new(value: v) }
  .map      { |v| v.to_s }                                          # => Success("20")
```

### Full API (symmetric across Success / Failure)

| Method | Success behavior | Failure behavior |
|---|---|---|
| `success?` / `failure?` | `true / false` | `false / true` |
| `value` / `error` | value / nil | nil / error |
| `and_then { \|v\| ... }` | calls block; **block must return a Result** | passes through |
| `map { \|v\| ... }` | wraps block result in `Success` | passes through |
| `recover { \|e\| ... }` | passes through | calls block; **block must return a Result** (lets you turn failure into success) |
| `unwrap!` | returns value | raises |
| `to_h` | `{status: :success, value:}` | `{status: :failure, error:}` |

`and_then` and `recover` raise `TypeError` if the block returns a non-Result.
That's intentional — it catches the single most common monad mistake
(forgetting to wrap the return value).

### `Result.try` — integrating exception-throwing code

Use `DAG::Result.try { ... }` to convert a block that might `raise` into a
`Result`. By default it catches `StandardError`; narrow with `error_class:`
if you want a different scope.

```ruby
DAG::Result.try { JSON.parse(input) }
# => Success(...) or
#    Failure({code: :try_raised, message: "JSON::ParserError: ...", error_class: "JSON::ParserError"})

DAG::Result.try(error_class: Errno::ENOENT) { File.read(path) }
# Only Errno::ENOENT becomes a Failure; other exceptions still propagate.
```

### `recover` — failure to success

```ruby
parse_config(path)
  .recover { |_| DAG::Success.new(value: DEFAULT_CONFIG) }
```

### Failure error shape

**Every `Failure` the library produces carries a `Hash` error with at least
`:code` (a `Symbol`) and `:message` (a `String`)**, plus optional fields
specific to the failure mode. This is the long-term contract — programmatic
consumers can branch on `error[:code]` without sniffing the value type, and
log lines can pull `error[:message]` for human-readable context.

```ruby
# Common shapes:

# exec failures
{ code: :exec_failed,        message: "...", exit_status: 1, command: "...", stdout: "...", stderr: "..." }
{ code: :exec_timeout,       message: "...", command: "...", timeout_seconds: 30 }
{ code: :exec_no_command,    message: "..." }

# file_read / file_write failures
{ code: :file_read_not_found,         message: "...", path: "..." }
{ code: :file_read_io_error,          message: "...", path: "...", error_class: "Errno::EACCES" }
{ code: :file_read_no_path,           message: "..." }
{ code: :file_write_no_path,          message: "..." }
{ code: :file_write_invalid_mode,     message: "...", mode: "x", valid_modes: ["w", "a"] }
{ code: :file_write_missing_from_input, message: "...", from: :upstream }
{ code: :file_write_no_content,       message: "..." }
{ code: :file_write_ambiguous_input,  message: "...", input_keys: [:a, :b] }
{ code: :file_write_io_error,         message: "...", path: "...", error_class: "Errno::ENOSPC" }

# ruby_script failures
{ code: :ruby_script_no_path,   message: "..." }
{ code: :ruby_script_not_found, message: "...", path: "..." }

# ruby callable failures
{ code: :ruby_no_callable,      message: "..." }
{ code: :ruby_callable_raised,  message: "...", error_class: "RuntimeError" }

# strategy / runner level
# (no :step field — the Runner wrapper already carries `failed_node`)
{ code: :step_raised,            message: "...", error_class: "...", strategy: :threads }
{ code: :step_bad_return,        message: "...", returned_class: "String", strategy: :threads }
{ code: :worker_died,            message: "...", strategy: :threads }
{ code: :child_crashed,          message: "...", error_class: "...", strategy: :processes }
{ code: :non_marshalable_result, message: "...", strategy: :processes }
{ code: :empty_child_payload,    message: "...", strategy: :processes }
{ code: :decode_failed,          message: "...", error_class: "...", strategy: :processes }
{ code: :workflow_timeout,       message: "...", timeout_seconds: 30 }

# schedule / layer admission
{ code: :deadline_exceeded,                         message: "...", not_after: "2026-04-15T10:00:00Z" }
{ code: :ttl_expired,                               message: "...", saved_at: "...", ttl_seconds: 300 }  # stale cause, not a step failure
{ code: :layer_admission_error,                     message: "...", error_class: "RuntimeError" }  # safety net for unexpected admission raises (malformed run_if, unparsable schedule, etc.)

# versioned / cross-workflow dependency resolution
{ code: :missing_dependency_version,                message: "...", dependency_name: :source, version: 2 }
{ code: :versioned_dependency_requires_execution_store, message: "...", dependency_name: :source, version: 2 }
{ code: :cross_workflow_resolver_missing,           message: "...", workflow_id: "pipeline-a", node_name: :validated_output, version: 2 }
{ code: :cross_workflow_resolution_failed,          message: "...", workflow_id: "pipeline-a", node_name: :validated_output, version: 2 }

# Result.try
{ code: :try_raised,         message: "...", error_class: "..." }
```

The `:step_bad_return` code is the safety net for the most common `:ruby`
footgun — a callable that returns a plain value instead of a
`DAG::Success` / `DAG::Failure`. The boundary check lives in
`Strategy.run_task`, so any executor (built-in or custom) that violates the
contract surfaces as a clean Failure on the failing step rather than
crashing in `Runner#resolve_input` on the next layer.

## Callbacks

```ruby
runner = DAG::Workflow::Runner.new(graph, registry,
  on_step_start: ->(name, step) { puts "Starting #{name}" },
  on_step_finish: ->(name, result) { puts "#{name}: #{result}" }
)
```

## API Reference

### Graph methods

| Method | Args | Return | Complexity |
|--------|------|--------|------------|
| `node_count` | -- | Integer | O(1) |
| `edge_count` | -- | Integer | O(V) |
| `add_node` | `name` | `self` | O(1) |
| `add_edge` | `from, to, **metadata` | `self` | O(V+E) (cycle check) |
| `remove_node` | `name` | `self` | O(deg) |
| `remove_edge` | `from, to` | `self` | O(1) |
| `replace_node` | `old_name, new_name` | `self` | O(deg) |
| `with_node` | `name` | frozen Graph | O(V+E) |
| `with_edge` | `from, to, **metadata` | frozen Graph | O(V+E) |
| `without_node` | `name` | frozen Graph | O(V+E) |
| `without_edge` | `from, to` | frozen Graph | O(V+E) |
| `with_node_replaced` | `old_name, new_name` | frozen Graph | O(V+E) |
| `node?` | `name` | Boolean | O(1) |
| `edge?` | `from, to` | Boolean | O(1) |
| `edges` | -- | Set[Edge] | O(E) / cached |
| `incoming_edges` | `node` | Set[Edge] | O(deg) |
| `edge_metadata` | `from, to` | Hash | O(1) |
| `successors` | `name` | Set | O(1) |
| `predecessors` | `name` | Set | O(1) |
| `indegree` / `outdegree` | `name` | Integer | O(1) |
| `roots` | -- | Set | O(V) / cached |
| `leaves` | -- | Set | O(V) / cached |
| `ancestors` | `name` | Set | O(V+E) |
| `descendants` | `name` | Set | O(V+E) |
| `path?` | `from, to` | Boolean | O(V+E) |
| `each_node` | `&block` | Enumerator/self | O(V) |
| `each_edge` | `&block` | Enumerator/self | O(E) |
| `topological_layers` | -- | Array[Array] | O(V+E) / cached |
| `topological_sort` | -- | Array | O(V+E) / cached |
| `shortest_path` | `from, to` | Hash or nil | O(V+E) |
| `longest_path` | `from, to` | Hash or nil | O(V+E) |
| `critical_path` | -- | Hash or nil | O(V+E) |
| `subgraph` | `node_names` | Graph | O(V+E) |
| `to_dot` | `name:` | String | O(V+E) |
| `to_h` | -- | Hash | O(V+E) |

"cached" means the result is computed once at `freeze` and returned on subsequent calls. `==` and `#hash` are **structural** (same node set + same edge set, with the same metadata) and work on frozen *and* unfrozen graphs alike — they never raise `FrozenError`. The usual caveat applies: if you store an unfrozen Graph as a `Hash` key or `Set` member and then mutate it, you will break the container's invariants. Freeze before using as a key.

### Runner

```ruby
DAG::Workflow::Runner.new(
  graph,                                    # DAG::Graph (frozen or not)
  registry,                                 # DAG::Workflow::Registry
  parallel:        true,                    # true/:threads (default), false/:sequential, :processes
  max_parallelism: DEFAULT_MAX_PARALLELISM, # [Etc.nprocessors, 8].min
  timeout:         nil,                     # wall-clock seconds, checked between layers; nil = no cap
  on_step_start:   nil,                     # ->(name, step) { ... }
  on_step_finish:  nil                      # ->(name, result) { ... }
).call
# => Success(value: {outputs:, trace:, error: nil}) or
#    Failure(error: {outputs:, trace:, error: {failed_node:, step_error:}})
```

#### Workflow timeout

`timeout:` is a wall-clock cap on the entire run, in seconds. It is checked
**between layers**: a layer that is already running will not be interrupted,
but no further layers start once the deadline passes. Per-step timeouts on
`:exec` and `:ruby_script` still apply inside a layer.

If the deadline trips, the runner returns a `Failure` with the standard
`{outputs:, trace:, error:}` shape; `error[:failed_node]` is
`:workflow_timeout` and `error[:step_error]` is
`{code: :workflow_timeout, message: "...", timeout_seconds: <n>}`.

A long pure-Ruby `:ruby` callable inside a single layer cannot be interrupted
by this library — there is no safe way to do that without the kind of
side-effects that come with `Thread#kill` or `Timeout.timeout`. If you need
hard isolation for a runaway step, use `:processes` (each step runs in its
own forked child and can be killed) or split the work into more layers.

## What this library does **not** do

ruby-dag is a DAG primitive plus a runner. It is intentionally small. In
particular it does **not** offer:

- **Retries / backoff.** A failed step fails the workflow. If you want
  retries, wrap the step yourself or build a thin retry layer over the
  callbacks.
- **Persistence / resume.** The trace and outputs live in memory. If the
  process crashes mid-run, all state is lost. There is no checkpoint store,
  no on-disk journal, and no "resume from step X".
- **Distributed execution.** Everything runs in one Ruby process (and its
  forked children for `:processes`). There is no network protocol, no
  scheduler, no worker pool across machines.
- **A scheduling/cron layer.** The runner runs once when you call it.
- **Cancellation of a running step.** The workflow-level `timeout:` halts
  *between* layers, not inside one. Per-step timeouts are only available
  for the built-in `:exec` and `:ruby_script` types via their own
  `timeout:` configs.
- **A web UI, REST API, or telemetry exporter.** Use the `on_step_start` /
  `on_step_finish` callbacks and the trace entries to wire your own.

If you need any of those, you want a real workflow engine (Temporal,
Airflow, Prefect, Sidekiq + a bespoke graph layer, etc.). ruby-dag is the
building block, not the platform.

### Parallel strategies

| Class | `parallel:` | Hard cap | Step constraints |
|---|---|---|---|
| `DAG::Workflow::Parallel::Sequential` | `false` / `:sequential` | n/a (always 1) | none |
| `DAG::Workflow::Parallel::Threads` | `true` / `:threads` (default) | yes | none |
| `DAG::Workflow::Parallel::Processes` | `:processes` | yes | result must be Marshal-able; requires `Process.fork` |

All three implement `#execute(tasks) { |name, result, started_at, finished_at, duration_ms| ... }`. Custom strategies can subclass `DAG::Workflow::Parallel::Strategy`.

## Performance

A small benchmark harness lives at `script/benchmark.rb`. It runs three
synthetic shapes (`fan_out`, `chain`, `mixed`) at two sizes (16 and 64 steps)
across two workload types (IO-bound `sleep 20ms` and CPU-bound naive
`fib(22)`), against the three stable strategies (`:sequential`, `:threads`,
`:processes`), and emits a markdown report.

```bash
ruby script/benchmark.rb                                # print to stdout
ruby script/benchmark.rb --out benchmarks/$(date +%Y-%m-%d).md
ruby script/benchmark.rb --quick                        # smaller matrix (~15s)
```

Each cell is the median of 3 wall-clock runs. Numbers are not portable
across machines — re-run on the target before drawing conclusions.

### Headline numbers

Apple Silicon (`arm64-darwin25`, 14 logical cores, `max_parallelism = 8`),
medians of 3 runs. Numbers below are pulled directly from the per-Ruby
baseline reports under [`benchmarks/`](benchmarks/) — re-run on your own
hardware before drawing conclusions.

#### `fan_out` — 64 IO-bound steps in one layer (`sleep 20ms` × 64)

This is the case where parallelism wins biggest: 64 independent
syscall-bound steps that all release the GVL.

| Ruby   | `:sequential` | `:threads` | `:processes` | Best speedup |
|---|---|---|---|---|
| 3.2.11 | 1.90s | 228.2ms | 236.1ms | **8.33×** (`:threads`) |
| 3.3.11 | 1.93s | 228.7ms | 235.3ms | **8.42×** (`:threads`) |
| 3.4.9  | 1.92s | 227.3ms | 236.4ms | **8.46×** (`:threads`) |
| 4.0.2  | 1.92s | 230.3ms | 233.9ms | **8.32×** (`:threads`) |

Threads scale right up to `max_parallelism` here because every step is
blocked on a syscall and the GVL is released. `:processes` matches within
noise; the fork cost is amortized across 64 long-ish steps.

#### `fan_out` — 64 CPU-bound steps in one layer (naive `fib(22)` × 64)

Pure-Ruby CPU work: threads can't beat the GVL, processes can.

| Ruby   | `:sequential` | `:threads`        | `:processes`           |
|---|---|---|---|
| 3.2.11 | 67.8ms        | 69.6ms (0.97×)    | **37.7ms (1.80×)**     |
| 3.3.11 | 76.3ms        | 74.6ms (1.02×)    | **35.8ms (2.13×)**     |
| 3.4.9  | 78.8ms        | 77.4ms (1.02×)    | **40.5ms (1.95×)**     |
| 4.0.2  | 65.2ms        | 67.5ms (0.97×)    | **35.9ms (1.81×)**     |

`:threads` adds essentially zero — GVL serializes the work. `:processes`
roughly doubles throughput because the fork/Marshal cost amortizes across
64 steps and each child runs on a real core.

#### `chain` — 64 sequential layers (no parallelism possible)

This isolates the per-layer scheduling overhead. With nothing to parallelize,
the strategies should converge on `:sequential`'s number, plus their fixed
overhead. Numbers from Ruby 3.4.9.

| Workload | `:sequential` | `:threads` | `:processes` |
|---|---|---|---|
| IO-bound (`sleep 20ms` × 64)  | 1.93s  | 1.92s (1.01×) | 2.02s (0.96×) |
| CPU-bound (`fib(22)` × 64)    | 77.8ms | 79.3ms (0.98×) | 139.5ms (0.56×) |

`:threads` overhead is invisible — within ±1% of sequential on both
workloads. `:processes` pays a per-layer `fork()` on every step: ~5% slower
on IO (where the syscall dominates) but **~80% slower on CPU**, where the
fork cost is large compared to a single `fib(22)` call. That's the
empirical argument for *not* defaulting to `:processes`.

#### `mixed` — 64 steps in 16 layers of width 4 (Ruby 3.4.9)

The realistic middle ground: a moderate fan-out in each layer.

| Workload | `:sequential` | `:threads` | `:processes` |
|---|---|---|---|
| IO-bound  | 1.96s  | 492.9ms (3.97×) | 502.9ms (3.89×) |
| CPU-bound | 78.1ms | 77.4ms (1.01×)  | 64.2ms (1.22×)  |

IO-bound speedup tracks the per-layer width (4×). CPU-bound `:processes`
still wins, but its margin shrinks because the per-layer fork cost gets
hit 16 times instead of once.

### When to pick which strategy

| If your workload is… | Pick |
|---|---|
| Mostly `exec` / `ruby_script` / `file_*` (default) | `:threads` (the default) |
| CPU-bound pure-Ruby `:ruby` steps you want to scale | `:processes` |
| Steps that might segfault / OOM and you need isolation | `:processes` |
| Tiny graphs (<8 steps) where startup dominates | `:sequential` is often fastest |
| You're debugging a race | `:sequential` |

The benchmark numbers are not a substitute for measuring your real workflow.
They're a sanity check that says: when you can use threads, use them; when
you can't, processes still beat sequential at scale; and the per-step
scheduling overhead is small enough that you don't need to think about it
unless your steps are sub-millisecond.

### Reproducing

```bash
ruby script/benchmark.rb --out benchmarks/$(date +%Y-%m-%d).md
```

Per-Ruby baselines for 3.2 / 3.3 / 3.4 / 4.0 are checked in under
[`benchmarks/`](benchmarks/) and regenerated before every release.

## Development

```bash
bundle exec rake          # test + lint
bundle exec rake test     # tests only
bundle exec standardrb    # lint
bundle exec standardrb --fix  # auto-fix
```

## License

[MIT](LICENSE)
