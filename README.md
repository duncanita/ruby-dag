# ruby-dag

Lightweight DAG workflow runner in pure Ruby. Zero runtime dependencies.

Define multi-step workflows as YAML, execute them with automatic dependency resolution and parallel execution.

## Install

```bash
git clone git@github.com:duncanita/ruby-dag.git
cd ruby-dag
bundle install
```

Requires Ruby 4.0+.

## Quick Start

### CLI

```bash
# Run a workflow
bin/dag examples/deploy.yml

# Dry run (show execution plan)
bin/dag examples/deploy.yml --dry-run

# Verbose output
bin/dag examples/deploy.yml --verbose

# Disable parallel execution
bin/dag examples/deploy.yml --no-parallel
```

### Ruby API

```ruby
require_relative "lib/dag"

# Build a graph programmatically
graph = DAG::Graph.new
  .add_node(name: :fetch, type: :exec, command: "curl -s https://api.example.com/data")
  .add_node(name: :process, type: :ruby, depends_on: [:fetch],
    callable: ->(input) { DAG::Success(JSON.parse(input)) })
  .add_node(name: :save, type: :file_write, path: "output.json", depends_on: [:process])

result = DAG::Runner.new(graph).call

if result.success?
  puts "Done! Outputs: #{result.value.keys}"
else
  puts "Failed at #{result.error[:failed_node]}: #{result.error[:error]}"
end
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
    command: "curl -X POST https://hooks.slack.com/... -d '{\"text\": \"Deployed!\"}'"
    depends_on: [push]
```

```bash
bin/dag deploy.yml --verbose
```

Output:
```
▶ test
  ✓ test
▶ build
  ✓ build
▶ push
  ✓ push
▶ notify
  ✓ notify

✓ Workflow completed (4 nodes)
```

## Node Types

| Type | Purpose | Required Config |
|------|---------|----------------|
| `exec` | Run a shell command | `command` |
| `script` | Run a Ruby script | `path` |
| `file_read` | Read a file | `path` |
| `file_write` | Write a file | `path` |
| `ruby` | Execute a lambda/proc | `callable` |
| `llm` | LLM prompt via command | `prompt`, `command` |

### exec

```yaml
fetch:
  type: exec
  command: "curl -s https://example.com"
  timeout: 30  # seconds, default 30
```

### script

```yaml
process:
  type: script
  path: "scripts/transform.rb"
  args: ["--format", "json"]  # optional, escaped automatically
  timeout: 60
```

### file_read / file_write

```yaml
read_config:
  type: file_read
  path: "config.yml"

write_output:
  type: file_write
  path: "output.txt"
  mode: "a"          # "w" (overwrite, default) or "a" (append)
  content: "hello"   # or receives input from dependency
  depends_on: [read_config]
```

### ruby (programmatic only)

```ruby
graph.add_node(
  name: :transform,
  type: :ruby,
  depends_on: [:fetch],
  callable: ->(input) { DAG::Success(input.upcase) }
)
```

### llm

Passes rendered prompt via `$DAG_LLM_PROMPT` environment variable to avoid shell injection.

```yaml
summarize:
  type: llm
  prompt: "Summarize this: {{input}}"
  command: "openclaw message send --stdin"
  timeout: 120
  depends_on: [fetch_data]
```

## Dependencies

Nodes declare dependencies with `depends_on`. The runner:

1. Computes execution layers via topological sort
2. Runs nodes in the same layer in parallel (via threads)
3. Passes output from completed nodes as input to dependents
4. Stops the entire workflow on first failure

```yaml
#        ┌─ b ─┐
#  a ────┤     ├──── d
#        └─ c ─┘

nodes:
  a:
    type: exec
    command: "echo start"
  b:
    type: exec
    command: "echo branch-b"
    depends_on: [a]
  c:
    type: exec
    command: "echo branch-c"
    depends_on: [a]
  d:
    type: ruby
    depends_on: [b, c]
    # receives {b: "branch-b", c: "branch-c"} as input
```

When a node has **one** dependency, it receives the value directly. With **multiple** dependencies, it receives a hash `{dep_name: value}`.

## Result Monad

Every step returns `Success(value)` or `Failure(error)`. Chain with railway semantics:

```ruby
DAG::Success(10)
  .and_then { |v| DAG::Success(v * 2) }
  .and_then { |v| v > 100 ? DAG::Failure("too big") : DAG::Success(v) }
  .map { |v| v.to_s }
# => Success("20")
```

## Callbacks

```ruby
runner = DAG::Runner.new(graph,
  on_node_start: ->(name, node) { puts "Starting #{name}" },
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
