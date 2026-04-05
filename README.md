# ruby-dag

Lightweight DAG workflow runner in pure Ruby. Zero runtime dependencies.

Define multi-step workflows as YAML or build them programmatically. Automatic dependency resolution and parallel execution via Ractors.

## Install

```bash
git clone git@github.com:duncanita/ruby-dag.git
cd ruby-dag
bundle install
```

Requires Ruby 4.0+.

## Architecture

Two layers, loosely coupled:

- **Graph** (`DAG::Graph`) -- pure DAG data structure. Nodes are symbols, edges are first-class. Enforces acyclicity. No workflow concepts.
- **Workflow** (`DAG::Workflow::*`) -- steps, types, YAML loading/dumping, parallel execution. Built on top of Graph.

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
  puts "Done! Outputs: #{result.value.keys}"
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

## Graph API

Pure DAG with no workflow awareness.

```ruby
# Build mutable
graph = DAG::Graph.new
graph.add_node(:a)
graph.add_node(:b)
graph.add_edge(:a, :b)
graph.freeze

# Or use the Builder
graph = DAG::Graph::Builder.build do |b|
  b.add_node(:a)
  b.add_node(:b)
  b.add_edge(:a, :b)
end  # => frozen

# Immutable builders (return new frozen graphs)
graph2 = graph.with_node(:c).with_edge(:b, :c)
```

### Queries

```ruby
graph.nodes              # => Set[:a, :b, :c]
graph.edges              # => Set[Edge(a -> b), ...]
graph.successors(:a)     # => Set[:b]
graph.predecessors(:b)   # => Set[:a]
graph.ancestors(:c)      # => Set[:a, :b]
graph.descendants(:a)    # => Set[:b, :c]
graph.roots              # => [:a]
graph.leaves             # => [:c]
graph.path?(:a, :c)      # => true
graph.indegree(:b)       # => 1
graph.outdegree(:a)      # => 1
graph.subgraph([:a, :b]) # => new Graph with only those nodes
```

### Topological Sort

```ruby
graph.topological_layers # => [[:a], [:b], [:c]]  -- parallel layers
graph.topological_sort   # => [:a, :b, :c]        -- flat order
```

### Validation

```ruby
result = DAG::Graph::Validator.validate(graph) do |v|
  v.rule("must have a single root") { |g| g.roots.size == 1 }
end

result.valid?  # => true/false
result.errors  # => ["Node x is disconnected", ...]

# Or raise on failure:
DAG::Graph::Validator.validate!(graph)
```

## Step Types

| Type | Purpose | Required Config |
|------|---------|----------------|
| `exec` | Run a shell command | `command` |
| `script` | Run a Ruby script | `path` |
| `file_read` | Read a file | `path` |
| `file_write` | Write a file | `path` |
| `ruby` | Execute a lambda/proc (programmatic only, not YAML-serializable) | `callable` |
| `llm` | LLM prompt via command | `prompt`, `command` |

## Dependencies

Nodes declare dependencies with `depends_on`. The runner:

1. Computes execution layers via Kahn's topological sort
2. Runs nodes in the same layer in parallel via Ractors
3. Passes output from completed nodes as input to dependents
4. Stops the workflow on first failure

When a node has **one** dependency, it receives the value directly. With **multiple** dependencies, it receives a hash `{dep_name: value}`.

## Result Monad

Every step returns `Success(value)` or `Failure(error)`:

```ruby
DAG::Success(10)
  .and_then { |v| DAG::Success(v * 2) }
  .and_then { |v| v > 100 ? DAG::Failure("too big") : DAG::Success(v) }
  .map { |v| v.to_s }
# => Success("20")
```

## Callbacks

```ruby
runner = DAG::Workflow::Runner.new(graph, registry,
  on_node_start: ->(name, step) { puts "Starting #{name}" },
  on_node_finish: ->(name, result) { puts "#{name}: #{result}" }
)
```

## Development

```bash
bundle exec rake          # test + lint
bundle exec rake test     # tests only
bundle exec rake coverage # tests with coverage report
bundle exec standardrb    # lint
bundle exec standardrb --fix  # auto-fix
```

## License

[AGPLv3](LICENSE)
