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

- **Graph** (`lib/dag/graph.rb`) -- pure DAG. Nodes are symbols, edges are `Data.define(:from, :to)`. Enforces acyclicity on every `add_edge`. Supports `freeze` for immutability. Key methods: `topological_layers`, `topological_sort`, `path?`, `ancestors`, `descendants`, `subgraph`, `with_node`, `with_edge`, `without_node`, `without_edge`, `remove_node`, `remove_edge`.
- **Workflow** (`lib/dag/workflow/`) -- steps with types (exec, ruby_script, file_read, file_write, ruby), a Registry mapping names to Steps, a Definition bundling Graph + Registry, a Loader (YAML/Hash -> Definition), a Dumper (Definition -> YAML), and a Runner (parallel execution via Ractors). LLM step is an extension: `require "dag/ext/llm"`.

Graph knows nothing about workflows. Workflow depends on Graph.

## Key files

```
lib/dag.rb                       # require entry point
lib/dag/version.rb               # DAG::VERSION constant
lib/dag/graph.rb                 # Graph class (DAG data structure)
lib/dag/graph/builder.rb         # Builder.build { |b| ... } -> frozen Graph
lib/dag/graph/validator.rb       # Structural validation with custom rules
lib/dag/workflow/step.rb         # Step = Data.define(:name, :type, :config)
lib/dag/workflow/registry.rb     # name -> Step mapping
lib/dag/workflow/definition.rb   # Definition = Data.define(:graph, :registry)
lib/dag/workflow/loader.rb       # YAML -> Definition
lib/dag/workflow/dumper.rb       # Definition -> YAML (inverse of Loader)
lib/dag/workflow/runner.rb       # Parallel execution via Ractors, TraceEntry
lib/dag/workflow/steps/          # Step type implementations (exec, ruby_script, etc.)
lib/dag/ext/llm.rb               # LLM step extension (opt-in)
lib/dag/result.rb                # Result monad interface
lib/dag/success.rb               # Success(value) with and_then, map
lib/dag/failure.rb               # Failure(error) with map_error
```

## Conventions

- Tests use Minitest in `spec/`, named `*_test.rb`
- `test_helper.rb` provides `build_test_workflow` helper
- All graph nodes are symbols internally (`.to_sym` on input)
- Core step types: exec, ruby_script, file_read, file_write, ruby
- Extension step types: llm (require "dag/ext/llm")
- The `ruby` step type carries a lambda and is not YAML-serializable; Dumper raises on it
- Step inputs are always hashes keyed by dependency name; zero-dep steps receive {}
- Runner result: `result.value[:outputs]` for step results, `result.value[:trace]` for execution trace
- Frozen graphs use `fetch_set` for safe hash lookup (avoids triggering default block)
- `Data.define` used for immutable value types: Edge, Step, Definition, Success, Failure, TraceEntry
- Cycle detection via `reachable?` (shared by `path?` and `would_create_cycle?`)
- Topological sort uses Kahn's algorithm, produces deterministic sorted layers
- Steps call `Ractor.make_shareable(self)` at construction (except :ruby type)
- Exec failures return structured hashes with :code, :command, :timeout keys

## Dumper round-trip property

`Loader.from_yaml(Dumper.to_yaml(definition))` produces an equivalent Definition for all serializable step types. This is tested against every example YAML.
