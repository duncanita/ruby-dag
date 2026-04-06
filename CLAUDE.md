# CLAUDE.md

## What this is

Ruby PORO DAG library for openclaw. An agent builds a workflow as a DAG, runs it with parallel execution via Ractors. Zero runtime dependencies.

## Commands

```bash
bundle exec rake          # test + lint
bundle exec rake test     # tests only
ruby -Ilib -Ispec -e 'Dir["spec/**/*_test.rb"].each { |f| require_relative f }'  # run tests without rake
```

## Architecture

Two layers:

- **Graph** (`lib/dag/graph.rb`) -- pure DAG. Nodes are symbols, edges are `Data.define(:from, :to, :metadata)`. Enforces acyclicity on every `add_edge`. Supports `freeze` for immutability with cached derived properties. Includes `Enumerable`. Key methods: `topological_layers`, `topological_sort`, `shortest_path`, `longest_path`, `critical_path`, `path?`, `ancestors`, `descendants`, `subgraph`, `incoming_edges`, `edge_metadata`, `to_dot`, `with_node`, `with_edge`, `without_node`, `without_edge`, `with_node_replaced`, `remove_node`, `remove_edge`, `replace_node`.
- **Workflow** (`lib/dag/workflow/`) -- steps with types (exec, ruby_script, file_read, file_write, ruby), a Registry mapping names to Steps (with `register`/`replace`/`remove`), a Definition bundling Graph + Registry (with `replace_step` returning a new Definition), a Loader (YAML/Hash -> Definition), a Dumper (Definition -> YAML), and a Runner (parallel execution via Ractors with capability-based degradation).

Graph knows nothing about workflows. Workflow depends on Graph.

## Key files

```
lib/dag.rb                       # require entry point
lib/dag/version.rb               # DAG::VERSION constant (0.2.0)
lib/dag/errors.rb                # Exception hierarchy (DAG::Error base)
lib/dag/edge.rb                  # Edge = Data.define(:from, :to, :metadata)
lib/dag/graph.rb                 # Graph class (DAG data structure, includes Enumerable)
lib/dag/graph/builder.rb         # Builder.build { |b| ... } -> frozen Graph
lib/dag/graph/validator.rb       # Structural validation with custom rules
lib/dag/workflow/step.rb         # Step = Data.define(:name, :type, :config), ractor_safe?
lib/dag/workflow/registry.rb     # name -> Step mapping
lib/dag/workflow/definition.rb   # Definition = Data.define(:graph, :registry)
lib/dag/workflow/loader.rb       # YAML -> Definition (supports edge metadata in depends_on)
lib/dag/workflow/dumper.rb       # Definition -> YAML (inverse of Loader)
lib/dag/workflow/runner.rb       # Parallel execution via Ractors, TraceEntry, conditional run_if
lib/dag/workflow/steps.rb        # Plugin registry (register/build/freeze_registry!)
lib/dag/workflow/steps/          # Step type implementations (exec, ruby_script, etc.)
lib/dag/result.rb                # DAG::Result marker module included by Success/Failure
lib/dag/success.rb               # Success(value:) with and_then, map
lib/dag/failure.rb               # Failure(error:) with map_error
```

## Error hierarchy

All errors inherit from `DAG::Error < StandardError`:

- `CycleError` -- adding edge would create cycle
- `DuplicateNodeError` -- adding node that already exists
- `UnknownNodeError` -- referencing non-existent node/edge
- `ValidationError` -- structural validation failure (has `.errors` array)
- `SerializationError` -- non-serializable step in Dumper
- `ParallelSafetyError` -- Ractor shareability violation

## Conventions

- Tests use Minitest in `spec/`, named `*_test.rb`
- `test_helper.rb` provides `build_test_workflow` helper
- All graph nodes are symbols internally (`.to_sym` on input)
- Core step types: exec, ruby_script, file_read, file_write, ruby
- The `ruby` step type carries a lambda and is not YAML-serializable; Dumper raises `SerializationError`
- Step inputs are always hashes keyed by dependency name; zero-dep steps receive {}
- Runner result: `result.value[:outputs]` for step results, `result.value[:trace]` for execution trace
- TraceEntry has `started_at`, `finished_at`, `duration_ms`, `status`, `input_keys` populated identically in parallel and sequential modes (skipped steps record `nil` timestamps)
- Frozen graphs use `fetch_set` for safe hash lookup (avoids triggering default block)
- `Data.define` used for immutable value types: Edge, Step, Definition, Success, Failure, TraceEntry
- Data.define objects are frozen after construction -- cannot add instance variables
- `DAG::Result` is a marker module included by Success/Failure (no methods); `is_a?(DAG::Result)` is the type check. There is no `DAG.Success(...)` factory — call `Success.new(value: ...)` / `Failure.new(error: ...)`.
- Cycle detection via `reachable?` (shared by `path?` and `would_create_cycle?`)
- Topological sort uses Kahn's algorithm with O(V+E) queue, produces deterministic sorted layers
- `shortest_path`, `longest_path`, and `critical_path` all share a single private `relax(sources, sentinel, &better)` helper that supports single- or multi-source relaxation in topological order
- Steps call `Ractor.make_shareable(self)` at construction (except :ruby type); non-shareable steps `warn`-degrade to sequential and `Step#ractor_safe?` returns false
- `Step#ractor_safe?` uses `Ractor.shareable?(self)` since Data.define objects can't store extra ivars
- Runner checks `ractor_safe?` per layer and degrades to sequential if any step is unsafe
- Conditional execution via `run_if:` lambda in step config; skipped steps get `:skipped` trace status
- Exec step uses raw `Process.spawn` + `IO.pipe` + `IO.select` draining (not `Open3.capture3`) so a wall-clock `timeout` can interrupt long-running commands; `Exec.run_command(command, timeout:)` is the shared spawn helper used by both `exec` and `ruby_script` steps
- Exec failures return structured hashes with `:code`, `:command`, `:timeout_seconds` (or `:exit_status`, `:stdout`, `:stderr`) keys
- Edge metadata stored in `@edge_metadata` hash keyed by `[from, to]` pairs; edges are lazy (no `@edges` ivar)
- Frozen graphs eagerly cache `topological_layers`, `roots`, `leaves` on freeze
- Plugin registry uses class-level `@registry` with `register`/`build`/`freeze_registry!` pattern
- Extensions register via `Steps.register(:type, Klass, yaml_safe: true)` instead of mutating constants
- `DAG::Graph::Validator::Report` (not `Result`) is the validation result type, to avoid collision with `DAG::Result`

## Dumper round-trip property

`Loader.from_yaml(Dumper.to_yaml(definition))` produces an equivalent Definition for all serializable step types. This includes edge metadata via expanded `depends_on` format. Tested against every example YAML.
