# CLAUDE.md

## What this is

Ruby PORO DAG library for openclaw. An agent builds a workflow as a DAG, runs it with pluggable parallel execution (Threads / Processes / Sequential strategies). Zero runtime dependencies.

## Commands

```bash
bundle exec rake          # test + lint
bundle exec rake test     # tests only
ruby -Ilib -Ispec -e 'Dir["spec/**/*_test.rb"].each { |f| require_relative f }'  # run tests without rake
```

## Architecture

Two layers:

- **Graph** (`lib/dag/graph.rb`) -- pure DAG. Nodes are symbols, edges are `Data.define(:from, :to, :metadata)`. Enforces acyclicity on every `add_edge`. Supports `freeze` for immutability with cached derived properties (layers, sort, roots, leaves, edges all eagerly cached on `freeze`). Iteration: `each_node` and `each_edge` are the ONLY entry points — `Graph` intentionally does NOT include `Enumerable` and has no top-level `each`, so `graph.map` / `graph.count` / `graph.include?` don't exist. Use `graph.each_node.map { ... }` / `graph.each_edge.count` / `graph.node?(name)` instead. Key methods: `each_node`, `each_edge`, `topological_layers`, `topological_sort`, `shortest_path`, `longest_path`, `critical_path`, `path?`, `ancestors`, `descendants`, `subgraph`, `incoming_edges`, `edge_metadata`, `to_dot`, `with_node`, `with_edge`, `without_node`, `without_edge`, `with_node_replaced`, `remove_node`, `remove_edge`, `replace_node`.
- **Workflow** (`lib/dag/workflow/`) -- steps with types (exec, ruby_script, file_read, file_write, ruby), a Registry mapping names to Steps (with `register`/`replace`/`remove`), a Definition bundling Graph + Registry (with `replace_step` returning a new Definition), a Loader (YAML/Hash -> Definition), a Dumper (Definition -> YAML), a Parallel::Strategy hierarchy with three adapters (Sequential, Threads, Processes), and a Runner that hands each layer to the configured strategy.

Graph knows nothing about workflows. Workflow depends on Graph.

## Key files

```
lib/dag.rb                       # require entry point
lib/dag/version.rb               # DAG::VERSION constant (0.3.0)
lib/dag/errors.rb                # Exception hierarchy (DAG::Error base)
lib/dag/edge.rb                  # Edge = Data.define(:from, :to, :metadata)
lib/dag/graph.rb                 # Graph class. Adjacency + reverse adjacency Sets. each_node / each_edge are the only iteration entry points; no Enumerable mixin, no top-level each.
lib/dag/graph/builder.rb         # Builder.build { |b| ... } -> frozen Graph
lib/dag/graph/validator.rb       # Structural validation. DEFAULT_RULES = [:no_isolated].freeze (on by default; opt out with defaults: []). AVAILABLE_RULES lists built-ins. Returns Validator::Report (named to avoid clash with DAG::Result).
lib/dag/workflow/step.rb         # Step = Data.define(:name, :type, :config). Pure data — knows nothing about strategies.
lib/dag/workflow/registry.rb     # name -> Step mapping
lib/dag/workflow/definition.rb   # Definition = Data.define(:graph, :registry)
lib/dag/workflow/loader.rb       # YAML -> Definition (supports edge metadata in depends_on)
lib/dag/workflow/dumper.rb       # Definition -> YAML (inverse of Loader)
lib/dag/workflow/runner.rb       # Coordinator: builds Tasks per layer, delegates to Parallel::Strategy, writes trace + fires callbacks. Handles run_if skipping. Builds {outputs:, trace:, error:} payload.
lib/dag/workflow/parallel.rb     # Parallel module + Task = Data.define(:name, :step, :input, :executor_class, :input_keys)
lib/dag/workflow/parallel/strategy.rb    # Abstract Strategy base. #execute(tasks) yielding [name, result, started_at, finished_at, duration_ms] in completion order. Class method .run_task(task) is the single place that stamps timings and rescues step errors into a Failure.
lib/dag/workflow/parallel/sequential.rb  # Default for parallel: false. Single-threaded loop. max_parallelism ignored.
lib/dag/workflow/parallel/threads.rb     # Default for parallel: true. Queue-based windowed Thread pool. No constraints on step results.
lib/dag/workflow/parallel/processes.rb   # parallel: :processes. Forks one child per task, ships result back via Marshal over IO.pipe with IO.select windowing. Results must be Marshal-able. Not on Windows.
lib/dag/workflow/steps.rb        # Plugin registry (register/build/freeze_registry!)
lib/dag/workflow/steps/          # Step type implementations (exec, ruby_script, etc.)
lib/dag/result.rb                # DAG::Result marker module included by Success/Failure. Also exposes Result.try { ... } to convert exception-throwing code into a Success/Failure, and Result.assert_result! used internally by and_then/recover to enforce the contract.
lib/dag/success.rb               # Success(value:) with and_then, map, recover (noop), unwrap!, to_h
lib/dag/failure.rb               # Failure(error:) with and_then (noop), map (noop), recover, unwrap! (raises), to_h
```

## Error hierarchy

All errors inherit from `DAG::Error < StandardError`:

- `CycleError` -- adding edge would create cycle
- `DuplicateNodeError` -- adding node that already exists
- `UnknownNodeError` -- referencing non-existent node/edge
- `ValidationError` -- structural validation failure (has `.errors` array)
- `SerializationError` -- non-serializable step in Dumper

Adding a duplicate edge is **not** an error — `add_edge` is idempotent and returns `self` if the edge already exists.

## Conventions

- Tests use Minitest in `spec/`, named `*_test.rb`
- `test_helper.rb` provides `build_test_workflow` helper
- All graph nodes are symbols internally (`.to_sym` on input)
- Core step types: exec, ruby_script, file_read, file_write, ruby
- The `ruby` step type carries a lambda and is not YAML-serializable; Dumper raises `SerializationError`
- Step inputs are always hashes keyed by dependency name; zero-dep steps receive {}
- Runner result has the same shape on both Success and Failure branches: `{outputs:, trace:, error:}`. On Success: `result.value[:outputs]` / `result.value[:trace]` / `result.value[:error] == nil`. On Failure: `result.error[:outputs]` / `result.error[:trace]` / `result.error[:error] == {failed_node:, step_error:}`. Top-level keys are identical so callers can read trace/outputs without branching first.
- Runner accepts `parallel:` as bool or symbol: `true`/`:threads` (default, Threads strategy), `false`/`:sequential`, `:processes`. Anything else (including the long-removed `:ractors`) raises `ArgumentError`.
- `max_parallelism:` defaults to `[Etc.nprocessors, 8].min`. Honored as a hard cap by Threads and Processes; always-1 for Sequential.
- TraceEntry has `started_at`, `finished_at`, `duration_ms`, `status`, `input_keys` populated identically in parallel and sequential modes (skipped steps record `nil` timestamps). In sequential mode the trace is in layer order; in parallel mode entries within a layer arrive in completion order, not submission order. Cross-layer order is preserved either way.
- `@adjacency` and `@reverse` are plain hashes (no default block); writes use `(hash[k] ||= Set.new) << v`, reads use `fetch_set` which returns a shared frozen `EMPTY_SET` on miss. Prevents auto-vivification on frozen hashes.
- `Data.define` used for immutable value types: Edge, Step, Definition, Success, Failure, TraceEntry
- Data.define objects are frozen after construction -- cannot add instance variables
- `DAG::Result` is a marker module included by Success/Failure, plus two module-level helpers: `Result.try { ... }` runs a block and returns `Success(return)` or `Failure("ExceptionClass: message")` (default `error_class: StandardError`, narrowable), and `Result.assert_result!(value, source)` is the internal guard that enforces `and_then` / `recover` blocks return a `Result`. `is_a?(DAG::Result)` is the type check. There is no `DAG.Success(...)` factory — call `Success.new(value: ...)` / `Failure.new(error: ...)`.
- Monad API (symmetric across Success/Failure): `success?` / `failure?`, `value` / `error`, `and_then { |v| ... }` (success-side chain; MUST return Result; Failure passes through), `map { |v| ... }` (Success only; Failure passes through), `recover { |e| ... }` (Failure-side chain; MUST return Result; Success passes through), `unwrap!`, `to_h`. `and_then` and `recover` raise `TypeError` if the block returns a non-Result — this is intentional, it catches the most common monad bug. Methods deliberately NOT shipped: `tap`, `tap_error`, `map_error`, `value_or`. Each was either trivially expressible in two lines of caller code or never used internally; the smaller surface is the long-term commitment.
- Cycle detection via the private `reachable?(from, to)` walker (shared by `add_edge`'s pre-insert check and `path?`)
- Topological sort uses Kahn's algorithm with O(V+E) queue, produces deterministic sorted layers
- `shortest_path`, `longest_path`, and `critical_path` all share a single private `relax(sources, sentinel, &better)` helper that supports single- or multi-source relaxation in topological order
- Step is pure data — does not know about strategies. Strategies see only `Parallel::Task` values built by the Runner.
- **Ractors strategy was removed in 0.3.0.** It used to ship as an experimental opt-in (`DAG_ENABLE_RACTORS=1`), but Ruby 4.0's per-Ractor deadlock detector trips on `Process.spawn`, which broke `:exec` and `:ruby_script` — the dominant step types. Keeping it gated behind a flag forced a `Strategy#supports?` / `@fallback_strategy` machinery in Runner that existed solely to support Ractors. Both the strategy and the fallback path are gone. If a future constrained backend (Fibers, WASI) needs the same shape, resurrect from git history (the last commit on `main` carrying ractors.rb) and reintroduce `supports?` then. **Do not add it back without that real driver.**
- Conditional execution via `run_if:` lambda in step config; skipped steps get `:skipped` trace status
- Exec step uses raw `Process.spawn` + `IO.pipe` + `IO.select` draining (not `Open3.capture3`) so a wall-clock `timeout` can interrupt long-running commands; `Exec.run_command(command, timeout:)` is the shared spawn helper used by both `exec` and `ruby_script` steps. `command` may be a String (interpreted by /bin/sh when it contains shell metacharacters) or an Array (passed as argv directly to execve, no shell). **Use the Array form for any value that did not come from a hard-coded literal in the source — period.** Do not try to escape input. `RubyScript` always passes an argv Array.
- **All `Failure` errors produced by the library are Hashes with at least `:code` (Symbol) and `:message` (String).** Optional fields are added per error mode (e.g. `:exit_status`, `:command`, `:stdout`, `:stderr` for `:exec_failed`; `:path` for file errors; `:strategy`, `:step` for parallel-strategy errors). No step type returns string-form errors anywhere — `Result.try` also produces a hash. User-constructed `Failure` values can still carry any payload; this rule is the library-side contract only.
- Step executor return-type contract is enforced at the `Strategy.run_task` boundary: an executor that returns anything other than a `DAG::Result` is wrapped in `Failure(code: :step_bad_return, ...)`. This is the safety net for `:ruby` callables that forget to wrap their return value in `Success`/`Failure`. Tested across all three strategies in `parallel_test.rb`.
- `Steps.class_for(type)` returns the registered Class for a step type without instantiating it. The Runner uses this to populate `Parallel::Task#executor_class` — there is no per-type instance cache in Runner anymore; the old `@executors[type] ||= Steps.build(type)` was building a throwaway instance just to call `.class` on it.
- Both subprocess managers (`Steps::Exec` and `Parallel::Processes`) share a single `KILL_GRACE_SECONDS` constant defined on `Steps::Exec`. `Processes` references it as `Steps::Exec::KILL_GRACE_SECONDS` rather than redefining its own — single source of truth for the TERM→KILL grace window.
- Edge metadata stored in `@edge_metadata` hash keyed by `[from, to]` pairs; edges are lazy (no `@edges` ivar)
- Frozen graphs eagerly cache `topological_layers`, `roots`, `leaves` on freeze
- Plugin registry uses class-level `@registry` with `register`/`build`/`freeze_registry!` pattern. `freeze_registry!` is opt-in and never called by the library — applications call it once after registering all custom step types.
- Extensions register via `Steps.register(:type, Klass, yaml_safe: true)` instead of mutating constants
- `DAG::Graph::Validator::Report` (not `Result`) is the validation result type, to avoid collision with `DAG::Result`
- `FileWrite` content resolution order: `config[:content]` (literal) → `config[:from]` → single-input value → Failure (multi-dep without `:from` is **not** silently `Hash#to_s`'d any more; it returns Failure)
- `Loader.from_yaml` and `Loader.from_hash` share a private `normalize_entries(node_defs, string_keys:)` helper that handles both string-key (YAML) and symbol-key (Hash) forms. Both public methods are 3 lines.
- `Graph#subgraph` is structured as `add_nodes_to(Graph.new, keep).then { |g| copy_internal_edges(g, keep) }` using two private helpers — preferred `.then` chain style with named extraction over inline `each_with_object` blocks
- `Graph#==` and `#hash` are **structural** and work on frozen and unfrozen graphs alike (no FrozenError). The caveat is the usual one: if you store an unfrozen Graph as a Hash key or Set member and then mutate it, you break the container. Freeze before using as a key. Use `node_count` / `edge_count` for cheap scalar queries that don't materialize the edge set.
- Node-collection return types are Sets throughout: `successors`, `predecessors`, `roots`, `leaves`, `incoming_edges`, and `nodes_with_no` (private) all return `Set`. `roots`/`leaves` are cached as frozen Sets on `freeze`. Use `each_root`/`each_leaf` if you want an ordered iterator.
- `Graph#to_dot` quotes any node or graph name that isn't a bare `[A-Za-z_][A-Za-z0-9_]*` identifier, and escapes embedded `"` and `\` inside the quoted form. Private helpers: `dot_id(name)` / `dot_quote(str)`.
- `Graph#replace_node` does not go through `add_edge` when rewiring preserved edges — it inserts directly via the private `insert_edge(from, to, metadata)` helper (no cycle re-check), because renaming a node in place can't introduce a cycle that wasn't there before.
- `Graph#add_edge` cost is O(V+E) per call because of the cycle-detection walk. Building a graph node-by-node is therefore O(V·(V+E)) total — fine for the workflow graphs this library targets. Documented inline on the method.
- Runner accepts `timeout:` (seconds, Numeric or nil). Checked between layers — a layer that has already started runs to completion. On trip, Runner returns `Failure(error: {outputs:, trace:, error: {failed_node: :workflow_timeout, step_error: {code: :workflow_timeout, message: "...", timeout_seconds: <n>}}})`. No way to interrupt mid-layer for `:ruby` callables; use `:processes` if you need hard isolation.
- `Parallel::Threads` worker uses an `ensure` block to guarantee exactly one push onto the result queue. The `begin` body rescues `StandardError` into a `Failure`; the `ensure` checks a `pushed` flag and pushes a synthetic "worker died without producing a result" `Failure` if the thread died below StandardError (or anywhere else) before the normal push. The worker thread also sets `Thread.current.report_on_exception = false` because worker death is already surfaced as a `Failure` — Ruby's default thread-death warning would be redundant double-reporting.
- `Parallel::Processes` drains each child's pipe **incrementally** with `read_nonblock` inside the same `IO.select` loop the windowing uses. EOF (returned as `nil` from `read_nonblock`) is the signal that a child is done. This avoids deadlock for payloads larger than one pipe buffer (~64 KB on Linux/macOS).
- `Parallel::Task = Data.define(:name, :step, :input, :executor_class, :input_keys)` is the unit handed to strategies. The Runner builds Tasks per layer, fires `on_step_start` callbacks before handing them off, then writes trace + fires `on_step_finish` as the strategy yields results.

## Dumper round-trip property

`Loader.from_yaml(Dumper.to_yaml(definition))` produces an equivalent Definition for all serializable step types. This includes edge metadata via expanded `depends_on` format. Tested against every example YAML.
