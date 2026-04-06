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

- **Graph** (`lib/dag/graph.rb`) -- pure DAG. Nodes are symbols, edges are `Data.define(:from, :to, :metadata)`. Enforces acyclicity on every `add_edge`. Supports `freeze` for immutability with cached derived properties. Includes `Enumerable`. Key methods: `topological_layers`, `topological_sort`, `shortest_path`, `longest_path`, `critical_path`, `path?`, `ancestors`, `descendants`, `subgraph`, `incoming_edges`, `edge_metadata`, `to_dot`, `with_node`, `with_edge`, `without_node`, `without_edge`, `remove_node`, `remove_edge`.
- **Workflow** (`lib/dag/workflow/`) -- steps with types (exec, ruby_script, file_read, file_write, ruby), a Registry mapping names to Steps, a Definition bundling Graph + Registry, a Loader (YAML/Hash -> Definition), a Dumper (Definition -> YAML), and a Runner (parallel execution via Ractors with capability-based degradation). LLM step is an extension: `require "dag/ext/llm"`.

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
lib/dag/ext/llm.rb               # LLM step extension (opt-in via Steps.register)
lib/dag/result.rb                # Result monad interface
lib/dag/success.rb               # Success(value) with and_then, map
lib/dag/failure.rb               # Failure(error) with map_error
```

## Error hierarchy

All errors inherit from `DAG::Error < StandardError`:

- `CycleError` -- adding edge would create cycle
- `DuplicateNodeError` -- adding node that already exists
- `UnknownNodeError` -- referencing non-existent node/edge
- `DuplicateEdgeError` -- adding duplicate edge
- `ValidationError` -- structural validation failure (has `.errors` array)
- `SerializationError` -- non-serializable step in Dumper
- `ParallelSafetyError` -- Ractor shareability violation

## Conventions

- Tests use Minitest in `spec/`, named `*_test.rb`
- `test_helper.rb` provides `build_test_workflow` helper
- All graph nodes are symbols internally (`.to_sym` on input)
- Core step types: exec, ruby_script, file_read, file_write, ruby
- Extension step types: llm (require "dag/ext/llm")
- The `ruby` step type carries a lambda and is not YAML-serializable; Dumper raises `SerializationError`
- Step inputs are always hashes keyed by dependency name; zero-dep steps receive {}
- Runner result: `result.value[:outputs]` for step results, `result.value[:trace]` for execution trace
- Frozen graphs use `fetch_set` for safe hash lookup (avoids triggering default block)
- `Data.define` used for immutable value types: Edge, Step, Definition, Success, Failure, TraceEntry
- Data.define objects are frozen after construction -- cannot add instance variables
- Cycle detection via `reachable?` (shared by `path?` and `would_create_cycle?`)
- Topological sort uses Kahn's algorithm with O(V+E) queue, produces deterministic sorted layers
- Steps call `Ractor.make_shareable(self)` at construction (except :ruby type); non-shareable steps silently degrade to sequential
- `Step#ractor_safe?` uses `Ractor.shareable?(self)` since Data.define objects can't store extra ivars
- Runner checks `ractor_safe?` per layer and degrades to sequential if any step is unsafe
- Conditional execution via `run_if:` lambda in step config; skipped steps get `:skipped` trace status
- Exec step uses `Open3.capture3` (not `popen3`) to avoid pipe buffer deadlock on >64KB output
- Exec failures return structured hashes with :code, :command, :timeout_seconds keys
- Edge metadata stored in `@edge_metadata` hash keyed by `[from, to]` pairs; edges are lazy (no `@edges` ivar)
- Frozen graphs eagerly cache `topological_layers`, `roots`, `leaves` on freeze
- Plugin registry uses class-level `@registry` with `register`/`build`/`freeze_registry!` pattern
- Extensions register via `Steps.register(:type, Klass, yaml_safe: true)` instead of mutating constants

## Dumper round-trip property

`Loader.from_yaml(Dumper.to_yaml(definition))` produces an equivalent Definition for all serializable step types. This includes edge metadata via expanded `depends_on` format. Tested against every example YAML.
