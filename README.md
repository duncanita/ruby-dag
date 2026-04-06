# ruby-dag

Lightweight DAG workflow runner in pure Ruby. Zero runtime dependencies.

Define multi-step workflows as YAML or build them programmatically. Automatic dependency resolution and parallel execution via Ractors.

**Version:** 0.2.0 | **License:** MIT | **Ruby:** >= 4.0

## Install

```bash
git clone git@github.com:duncanita/ruby-dag.git
cd ruby-dag
bundle install
```

## Architecture

Two layers, loosely coupled:

- **Graph** (`DAG::Graph`) -- pure DAG data structure. Nodes are symbols, edges carry optional metadata. Enforces acyclicity. Includes `Enumerable`. No workflow concepts.
- **Workflow** (`DAG::Workflow::*`) -- steps, types, YAML loading/dumping, parallel execution with capability-based degradation. Built on top of Graph.

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

### Load and Run

```ruby
require_relative "lib/dag"

definition = DAG::Workflow::Loader.from_file("deploy.yml")
runner = DAG::Workflow::Runner.new(definition.graph, definition.registry)
result = runner.call

if result.success?
  outputs = result.value[:outputs]
  trace = result.value[:trace]
  puts "Done! Steps: #{outputs.keys}, Trace: #{trace.size} entries"
else
  puts "Failed at #{result.error[:failed_node]}: #{result.error[:error]}"
end
```

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

## Graph API

Pure DAG with no workflow awareness. Includes `Enumerable` (iterates over nodes).

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
graph.size               # => 3
graph.empty?             # => false
graph.node?(:a)          # => true
graph.edge?(:a, :b)      # => true
graph.nodes              # => Set[:a, :b, :c]
graph.edges              # => Set[Edge(a -> b), ...]  (lazy, computed on each call)
graph.incoming_edges(:c) # => [Edge(b -> c)]
graph.successors(:a)     # => Set[:b]
graph.predecessors(:b)   # => Set[:a]
graph.ancestors(:c)      # => Set[:a, :b]
graph.descendants(:a)    # => Set[:b, :c]
graph.roots              # => [:a]         (cached if frozen)
graph.leaves             # => [:c]         (cached if frozen)
graph.path?(:a, :c)      # => true
graph.indegree(:b)       # => 1
graph.outdegree(:a)      # => 1
graph.subgraph([:a, :b]) # => new Graph with only those nodes

# Enumerable (iterates over nodes)
graph.map { |n| n.upcase }
graph.select { |n| graph.indegree(n) == 0 }
graph.count              # => 3
graph.include?(:a)       # => true

# Serialization
graph.to_h               # => {nodes: [:a, :b, :c], edges: [{from: :a, to: :b}, ...]}
graph.to_dot             # => "digraph dag {\n  a;\n  b;\n  a -> b;\n}"
graph.to_dot(name: "my_dag")
```

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

```ruby
result = DAG::Graph::Validator.validate(graph) do |v|
  v.rule("must have a single root") { |g| g.roots.size == 1 }
end

result.valid?  # => true/false
result.errors  # => ["Node x is isolated (no edges)", ...]

# Or raise on failure:
DAG::Graph::Validator.validate!(graph)
```

## Step Types

### Core Types

| Type | Purpose | Required Config | YAML-safe |
|------|---------|----------------|-----------|
| `exec` | Run a shell command | `command` | yes |
| `ruby_script` | Run a Ruby script file | `path` | yes |
| `file_read` | Read a file | `path` | yes |
| `file_write` | Write a file | `path` | yes |
| `ruby` | Execute a lambda/proc | `callable` | no |

### Custom Step Types

Register custom step types via the plugin registry:

```ruby
DAG::Workflow::Steps.register(:my_type, MyStepClass, yaml_safe: true)
DAG::Workflow::Steps.freeze_registry!  # optional: locks registry, makes Ractor-shareable
```

## Ractor Parallel Execution

Steps in the same topological layer run in parallel via Ractors when `parallel: true` (default).

The Runner checks `Step#ractor_safe?` for each layer. If any step in a layer is not Ractor-safe (e.g., `:ruby` type or non-shareable config), that layer degrades to sequential execution automatically.

```ruby
step = DAG::Workflow::Step.new(name: :fetch, type: :exec, command: "echo hi")
step.ractor_safe?  # => true

step = DAG::Workflow::Step.new(name: :compute, type: :ruby, callable: -> { 42 })
step.ractor_safe?  # => false (lambdas can't be shared across Ractors)
```

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

Downstream steps receive `nil` for skipped dependencies.

## Dependencies

Nodes declare dependencies with `depends_on`. The runner:

1. Computes execution layers via Kahn's topological sort (O(V+E))
2. Checks Ractor safety per layer, degrades to sequential if needed
3. Runs nodes in the same layer in parallel via Ractors
4. Checks `run_if` conditions before execution
5. Passes output from completed nodes as input to dependents
6. Stops the workflow on first failure

Step inputs are **always** hashes keyed by dependency step name (e.g., `{ fetch: "data" }`). Zero-dependency steps receive `{}`.

## Execution Contract

- Step inputs are always hashes keyed by dependency step name. Zero-dependency steps receive `{}`.
- Step outputs should be JSON-like values (strings, numbers, booleans, arrays, hashes) when using parallel execution. Arbitrary Ruby objects work only in sequential mode.
- Callback ordering is per-step but not globally deterministic across nodes in the same parallel layer.
- On first step failure, the workflow halts. Completed outputs and failure details are returned.
- Successful results include an execution trace: `result.value[:trace]` is an array of `TraceEntry` with `:name`, `:layer`, `:duration_ms`, `:status` (`:success`, `:failure`, or `:skipped`).
- Failed results include a partial trace: `result.error[:trace]`.

## Error Handling

All errors inherit from `DAG::Error < StandardError`:

| Error | When raised |
|-------|-------------|
| `CycleError` | `add_edge` would create a cycle |
| `DuplicateNodeError` | `add_node` with existing name |
| `UnknownNodeError` | Reference to non-existent node or edge |
| `DuplicateEdgeError` | Adding a duplicate edge |
| `ValidationError` | Structural validation failure (has `.errors` array) |
| `SerializationError` | Dumper encounters non-serializable step (`:ruby`) |
| `ParallelSafetyError` | Ractor shareability violation |

```ruby
rescue DAG::Error => e     # catches all DAG errors
rescue DAG::CycleError => e # catches only cycle errors
```

## Result Monad

Every step returns a `DAG::Success` or `DAG::Failure`:

```ruby
DAG::Success.new(value: 10)
  .and_then { |v| DAG::Success.new(value: v * 2) }
  .and_then { |v| v > 100 ? DAG::Failure.new(error: "too big") : DAG::Success.new(value: v) }
  .map { |v| v.to_s }
# => Success("20")
```

Exec step failures return structured error hashes:

```ruby
# { code: :exec_failed, exit_status: 1, command: "...", stdout: "...", stderr: "..." }
# { code: :exec_timeout, command: "...", timeout_seconds: 30 }
```

## Callbacks

```ruby
runner = DAG::Workflow::Runner.new(graph, registry,
  on_step_start: ->(name, step) { puts "Starting #{name}" },
  on_step_finish: ->(name, result) { puts "#{name}: #{result}" }
)
```

## API Reference

### Graph Methods

| Method | Args | Return | Complexity |
|--------|------|--------|------------|
| `add_node` | `name` | `self` | O(1) |
| `add_edge` | `from, to, **metadata` | `self` | O(V+E) (cycle check) |
| `remove_node` | `name` | `self` | O(deg) |
| `remove_edge` | `from, to` | `self` | O(1) |
| `with_node` | `name` | frozen Graph | O(V+E) |
| `with_edge` | `from, to, **metadata` | frozen Graph | O(V+E) |
| `without_node` | `name` | frozen Graph | O(V+E) |
| `without_edge` | `from, to` | frozen Graph | O(V+E) |
| `node?` | `name` | Boolean | O(1) |
| `edge?` | `from, to` | Boolean | O(1) |
| `edges` | -- | Set[Edge] | O(E) |
| `incoming_edges` | `node` | Array[Edge] | O(deg) |
| `edge_metadata` | `from, to` | Hash | O(1) |
| `successors` | `name` | Set | O(1) |
| `predecessors` | `name` | Set | O(1) |
| `roots` | -- | Array | O(V) / cached |
| `leaves` | -- | Array | O(V) / cached |
| `ancestors` | `name` | Set | O(V+E) |
| `descendants` | `name` | Set | O(V+E) |
| `path?` | `from, to` | Boolean | O(V+E) |
| `topological_layers` | -- | Array[Array] | O(V+E) / cached |
| `topological_sort` | -- | Array | O(V+E) / cached |
| `shortest_path` | `from, to` | Hash or nil | O(V+E) |
| `longest_path` | `from, to` | Hash or nil | O(V+E) |
| `critical_path` | -- | Hash or nil | O(V+E) |
| `subgraph` | `node_names` | Graph | O(V+E) |
| `to_dot` | `name:` | String | O(V+E) |
| `to_h` | -- | Hash | O(V+E) |

"cached" means the result is computed once at `freeze` and returned on subsequent calls.

## Development

```bash
bundle exec rake          # test + lint
bundle exec rake test     # tests only
bundle exec standardrb    # lint
bundle exec standardrb --fix  # auto-fix
```

## License

[MIT](LICENSE)
