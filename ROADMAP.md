# ruby-dag Roadmap

> Baseline: ruby-dag v0.4.0
> Analysis date: 2026-04-14
> Scope: features that belong in the generic DAG/workflow gem, not in application-specific layers

This document is the implementation-oriented roadmap for future ruby-dag features.
It is intentionally stricter than a product wishlist. Every section below is
written to remove ambiguity for the engineer who eventually implements it.

## Reality check: revised status as of 2026-04-19

This roadmap was originally written as a clean forward plan before a large part
of the runtime work had landed. Since then, implementation progressed through a
mix of refactor-first slices, test-driven feature slices, and example-driven
hardening. As a result, the repository no longer matches the original
"not-started / partial / implemented" labels in this file.

This revised version keeps the original architectural intent, but updates the
document to answer three practical questions clearly:

1. where the codebase actually is now
2. why implementation did not follow the roadmap in a neat linear order
3. what remains to finish the roadmap deliberately instead of wandering feature-by-feature

### Why implementation did not follow the roadmap exactly

The short version: the roadmap was directionally right, but real development
followed the seams that made the code safer to evolve.

The main reasons were:

- refactor-first pressure in `Runner`: several roadmap items wanted to add more
  behavior to the runtime hotspot, so work first extracted collaborators such as
  scheduling policy, execution persistence, layer admission, trace recording,
  and task completion handling
- vertical slices beat abstract milestones: instead of "finish Feature N in one
  shot", many changes landed as narrow end-to-end slices with tests, examples,
  and docs together
- later roadmap items unlocked earlier partials: versioned outputs,
  invalidation, event emission, cross-workflow waiting, and subtree mutation
  were often easier to implement once the runtime seams were in place, even if
  the original roadmap listed them later
- durable execution semantics were discovered through examples: file-store,
  invalidation, subtree replacement, and nested sub-workflow examples exposed
  real edge cases that reshaped the order of work

So the roadmap was not ignored; it was executed opportunistically around the
real code seams. This matters because the remaining work is now less about
starting untouched features and more about closing the gaps in partially-landed
areas.

### Where we are now

- the runtime foundations are in place and actively supporting real features
- retry, middleware, context injection, pause/resume, event emission,
  versioned outputs, invalidation, and substantial cross-workflow dependency
  support all exist in code
- checkpointing/resume, sub-workflow composition, scheduling, dynamic mutation,
  and cross-workflow dependencies still have "finish the contract" work left
- the most important remaining task is no longer inventing new primitives; it
  is tightening documented semantics so the implementation and roadmap line up

### How to read statuses in this revised document

- `implemented`: the feature exists in the repo in a form that matches the
  roadmap closely enough to be considered landed
- `partial`: the feature is real and usable, but either the contract differs
  from the original roadmap or important boundary cases / docs / validation are
  still incomplete
- `not-started`: still genuinely absent

## Principle: what belongs in the gem vs. what stays out of scope

ruby-dag is a generic DAG execution engine. Features belong here if they are
useful to any DAG-based workflow system, not just LLM agents. Higher-level
applications can build on top of ruby-dag for product-specific concerns such as
agents, prompts, model adapters, channels, dashboards, API layers, and
application orchestration.

| Belongs in ruby-dag | Belongs outside ruby-dag |
|---------------------|--------------------------|
| Checkpointing, resume, retry | LLM step types, planner logic |
| Sub-workflow composition | Agent compilation, routing |
| Context injection into handlers | App-specific runtime registries |
| Scheduling constraints on nodes | Multi-tenant isolation |
| Persistent execution state primitives | Dashboard, API layer |
| Graph mutation during execution | Cost optimization, audit products |
| Invalidation cascade | Experience replay |

---

## Current capabilities (revised as of 2026-04-19)

- Graph: nodes, edges, topological sort, layers, shortest/longest/critical path, subgraph, DOT export, immutable builders, `each_successor`, immutable subtree replacement helpers
- Workflow: synchronous `Runner#call` with 3 parallel strategies (`sequential`, `threads`, `processes`)
- Steps: `exec`, `ruby_script`, `file_read`, `file_write`, `ruby` (Proc), `sub_workflow`, custom registration
- Conditional execution: callable `run_if` for programmatic workflows and declarative `run_if` DSL for YAML/programmatic definitions
- Middleware/runtime seams: step middleware, retry middleware, event middleware, structured logging example middleware, runner collaborators for scheduling/admission/persistence/trace completion
- Durable execution: `ExecutionStore`, in-memory store, file-backed store, durable fingerprints, reusable outputs, `clear_on_completion:`, pause flags, waiting state, stale/obsolete markers
- Scheduling/history: `not_before`, `not_after`, `ttl`, cron metadata round-trip, versioned outputs, invalidation helpers, subtree replacement impact helpers
- Cross-workflow and nesting: namespaced sub-workflow persistence, versioned dependency inputs, cross-workflow resolver support, nested event emission, nested invalidation
- Timeouts: per-step (`exec`, `ruby_script`) plus workflow wall-clock timeout checked between layers
- Result model: workflow-level `RunResult` plus step-level `Success` / `Failure`
- Trace/callbacks: flat `TraceEntry` history, attempt tracing, `on_step_start`, `on_step_finish`
- YAML: Loader/Dumper with round-trip fidelity, edge metadata, declarative `run_if`, version metadata, and sub-workflow `definition_path:` support
- Validation: graph validation, workflow-level `run_if` reference validation, retry/event/dependency/mutation validation, durable execution guardrails

---

## Current code constraints

The roadmap must respect the actual shape of the codebase today:

- `DAG::Workflow::Step` is immutable data. Step config is deep-copied and frozen at construction time.
- `Runner` is synchronous and layer-based. It does not keep background state and it does not currently expose a long-lived handle.
- Parallel execution is strategy-driven. Strategies currently invoke `executor_class.new.call(step, input)` and return `DAG::Result`.
- Step inputs are always hashes keyed by dependency name. Zero-dependency steps receive `{}`.
- `DAG::Result` is a step-level contract, not a workflow-lifecycle contract.
- Current callbacks are observational only. They are not a durable state model.
- `TraceEntry` is currently a flat, append-only per-step attempt record. It is not durable state.
- Loader/Dumper are intentionally strict. YAML only supports YAML-safe step types and YAML-safe config shapes.
- Graph mutation today includes immutable subtree replacement plus persisted impact helpers, but it is still intentionally between-invocations and narrower than fully general live graph surgery.

Any roadmap item that conflicts with these constraints must either:

1. define a clear major-version API change, or
2. introduce a new layer without pretending the current API already supports it.

---

## Locked architecture decisions

The following design choices are fixed for this roadmap. Later feature sections
must not contradict them.

### 1. `Runner#call` remains the core execution primitive

The gem keeps a synchronous execution core. It does not grow a long-lived,
in-memory workflow engine as its primary abstraction.

- The core executor remains `Runner#call`.
- Repeated invocations, pause flags, schedule wakeups, and cross-workflow waits
  are modeled through persisted execution state plus a higher-level
  coordinator, not through `Runner.start`, `RunHandle`, or internal threads.
- The coordinator may live in the gem later, but it is layered on top of
  persisted state and `Runner#call`, not instead of it.

### 2. Step results are monads; workflow state is not

`DAG::Success` / `DAG::Failure` remain the monadic contract for one step
attempt. Future workflow execution uses dedicated immutable value objects with
explicit invariants instead of a second monad layer.

```ruby
RunResult = Data.define(
  :status,        # :completed | :failed | :waiting | :paused
  :workflow_id,
  :outputs,       # Hash[node_path, DAG::Result] for completed nodes only
  :trace,         # Array[TraceEntry]
  :error,         # nil or workflow-level error hash
  :waiting_nodes  # Array[node_path]
)
```

Definitions:

- `:completed`: all required nodes finished successfully or were intentionally skipped
- `:failed`: at least one node failed and the workflow halted
- `:waiting`: no runnable work remains in this invocation, but at least one node is waiting on time, approval, external data, or pause gate
- `:paused`: a pause flag was observed between layers and execution stopped cleanly

Rules:

- `DAG::Result` stays step-attempt scoped.
- `RunResult` is not a monad. It is a workflow-level immutable value object.
- `Step`, `Definition`, `StepExecution`, `TraceEntry`, and durable execution
  records are immutable value objects, not monads.

`RunResult` invariants:

- `status` is one of `:completed`, `:failed`, `:waiting`, `:paused`.
- `outputs` contains only completed or intentionally skipped node outputs.
- `error` is present only when `status == :failed`.
- `waiting_nodes` is non-empty only when `status == :waiting`.
- `trace` is append-only attempt history. It is not the source of truth for
  node lifecycle state.

### 3. Durable state is unified under `ExecutionStore`

The roadmap does not split persistence into unrelated `CheckpointStore`,
`VersionStore`, and ad hoc pause/stale state. All durable execution state lives
behind one store protocol.

```ruby
class ExecutionStore
  def begin_run(workflow_id:, definition_fingerprint:, node_paths:) = nil
  def load_run(workflow_id) = nil

  def load_node(workflow_id:, node_path:) = nil
  def set_node_state(workflow_id:, node_path:, state:, reason: nil, metadata: {}) = nil

  def append_trace(workflow_id:, entry:) = nil

  def save_output(workflow_id:, node_path:, version:, result:, reusable:, superseded:) = nil
  def load_output(workflow_id:, node_path:, version: :latest) = nil

  def mark_stale(workflow_id:, node_paths:, cause:) = nil
  def set_workflow_status(workflow_id:, status:, waiting_nodes: []) = nil
  def set_pause_flag(workflow_id:, paused:) = nil
end
```

Required durable concepts:

- workflow fingerprint
- workflow status
- node lifecycle state
- reusable output pointer for resume
- version history for completed successful outputs
- pause flag
- stale/superseded markers
- append-only attempt trace

### 4. Node lifecycle state is durable state, not trace status

Durable node states:

```text
:pending, :running, :waiting, :completed, :failed, :stale
```

Attempt trace statuses:

```text
:success, :failure, :skipped
```

Rules:

- `:waiting`, `:stale`, and `:paused` are not `DAG::Result` branches.
- A waiting node does not produce `Success(nil)`.
- A stale node is a previously completed node whose reusable output has been superseded.
- A paused workflow is a workflow-level state, not a node-level state.

### 5. Trace stays flat and append-only

The roadmap standardizes on a flat trace with `node_path` and `depth`, not a
nested `children:` tree.

```ruby
TraceEntry = Data.define(
  :node_path,      # Array[Symbol], e.g. [:process, :summarize]
  :layer,          # Integer, relative to current definition
  :attempt,        # Integer, 1-based
  :started_at,
  :finished_at,
  :duration_ms,
  :status,         # :success | :failure | :skipped
  :input_keys,
  :retried,        # Boolean
  :depth           # Integer, 0 = top-level
)
```

Nested sub-workflow traces are represented by `node_path` prefixes and `depth`,
not by embedding arrays of child trace entries.

### 6. Middleware is the primary execution extension point

Retry, checkpoint persistence, and event emission are implemented as middleware
wrapping step execution. Graph traversal, dependency resolution, scheduling
eligibility, and workflow state transitions remain runner responsibilities.

```ruby
class StepMiddleware
  def call(step, input, context:, execution:, next_step:)
    next_step.call(step, input, context: context, execution: execution)
  end
end
```

`execution` is internal runner metadata made available to middleware:

```ruby
StepExecution = Data.define(
  :workflow_id,
  :node_path,
  :attempt,
  :deadline,
  :depth,
  :parallel,
  :execution_store,
  :event_bus
)
```

`StepExecution` invariants:

- one instance exists per node attempt
- `attempt` is an integer `>= 1`
- `node_path` is unique within one logical workflow run
- `deadline` is monotonic-time based when present
- `execution_store` and `event_bus` may be `nil` only when the corresponding
  feature is disabled

Milestone 0 changes the current strategy handoff. The runner becomes
responsible for composing one attempt invoker per task:

- resolve dependency inputs
- build `StepExecution`
- wrap the core step call with middleware
- pass the prepared attempt callable to the strategy

Strategies remain responsible only for executing prepared attempts and yielding
`DAG::Result` plus timing. They do not own graph traversal, stores, event
delivery, or lifecycle decisions.

Middleware order is declaration order, first middleware outermost.

### 7. Time uses an injected `Clock`

Time-based features use one explicit protocol instead of calling wall-clock or
monotonic time ad hoc throughout the runtime.

```ruby
class Clock
  def wall_now = Time.now.utc
  def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
```

Rules:

- `wall_now` governs `not_before`, `not_after`, `cron`, and `ttl`.
- `monotonic_now` governs workflow deadlines, retry backoff, timeout
  budgeting, and duration measurements.
- The default implementation is a system clock.
- Tests use injected fake clocks instead of real sleeping.

### 8. Context injection is application data, not runtime state

Feature 4 introduces explicit `context:` for step handlers. It is separate from
runner execution metadata.

- Step handlers receive `context:` only if they opt into it.
- Middleware receives both `context:` and `execution:`.
- Built-in coordination data such as workflow ID, remaining timeout, or store
  handle does not ride through the user context object.

### 9. Durable features require a stable definition fingerprint

Checkpointing, resume, versioning, invalidation, scheduling, and pause/resume
all rely on reproducible workflow fingerprints.

Fingerprint rules:

- YAML-safe definitions use canonical dumper output as the fingerprint source.
- Built-in non-YAML-safe step types must provide a deterministic fingerprint strategy.
- `:ruby` steps are not resumable/versionable by default. They require an
  explicit `resume_key:` in config to participate in durable features.
- Custom step types must supply a deterministic fingerprint hook at
  registration time if durable features are enabled.

If persistence is enabled and any step cannot be fingerprinted, runner
construction fails with `ValidationError`.

---

## Milestone 0: Runtime Foundations

All features below assume Milestone 0 lands first. It is a prerequisite
milestone, not Feature 0.

### Scope

- Introduce workflow-level `RunResult` with the invariants above.
- Introduce `ExecutionStore` as the single durable state interface.
- Introduce deterministic fingerprinting hooks and validation.
- Introduce injected `Clock` support for wall and monotonic time.
- Replace the current direct strategy handoff with runner-built attempt
  invokers wrapped in middleware.

### Acceptance criteria

- `Runner#call` still supports non-persistent execution without `workflow_id`.
- Store-backed runs fail fast on missing fingerprint hooks or invalid durable
  configuration.
- Strategies execute prepared attempt callables and remain agnostic to stores,
  event buses, and workflow lifecycle.
- Time-based tests can run against a fake clock without real sleeping.
- Trace and node-path invariants hold across retries and nested sub-workflows.

**Status:** `partial` | **Complexity:** large

Current repo reality: most of Milestone 0 is landed in practice (`RunResult`,
`ExecutionStore`, fingerprinting, `Clock`, middleware handoff, runner
collaborators). It remains `partial` only because the milestone was delivered
incrementally and some later feature contracts ended up refining the foundation
instead of waiting for a single formal "Milestone 0 complete" moment.

---

## Feature 1: Step Retry with Backoff

Retry is implemented as built-in middleware over one node attempt.

### Public API

```ruby
Step.new(
  name: :fetch_data,
  type: :exec,
  command: "curl ...",
  retry: {
    max_attempts: 3,
    backoff: :exponential,   # :fixed, :exponential, :linear
    base_delay: 1.0,         # seconds
    max_delay: 30.0,         # seconds
    retry_on: [:exec_failed, :exec_timeout] # default: all failure codes
  }
)

runner = Runner.new(definition, middleware: [DAG::Workflow::RetryMiddleware.new])
```

### Exact semantics

- `max_attempts` includes the first attempt. `3` means `1` initial attempt plus up to `2` retries.
- Retry is evaluated only for `Failure` results returned by the step attempt.
- `retry_on` matches `result.error[:code]`.
- Backoff formulas:
  - `:fixed`: `base_delay`
  - `:linear`: `base_delay * retry_index`
  - `:exponential`: `base_delay * (2 ** (retry_index - 1))`
- Delay is capped at `max_delay`.
- Backoff time is measured against `clock.monotonic_now` and counts against the workflow deadline.
- Backoff holds the current worker slot. Under `:threads` and `:processes`,
  the same worker remains occupied until the retry chain succeeds or exhausts.
- Retry remains inside the current worker and middleware chain. It is not
  rescheduled through the runner.
- The middleware appends one trace entry per attempt.
- Earlier failed attempts are marked `retried: true`.
- Callbacks remain observational. The retry contract does not depend on adding a new callback status.

### Acceptance criteria

- A retryable failure with `max_attempts: 3` produces at most `3` attempts.
- A non-matching error code does not retry.
- Hitting the workflow deadline during backoff or later attempt returns workflow failure.
- Final failure payload includes all attempt errors in order.
- Successful later attempt persists only the successful output as reusable.
- With `max_parallelism: 1`, a step in backoff prevents another runnable step
  from starting until that retry chain completes or fails.

**Status:** `implemented` | **Priority:** high

---

## Feature 2: Checkpointing and Resume

Checkpointing is the reusable-output layer of `ExecutionStore`. Resume means:
reuse completed successful outputs whose definition fingerprint still matches.

### Public API

```ruby
store = DAG::Workflow::ExecutionStore::FileStore.new(dir: "/var/checkpoints")

runner = Runner.new(definition,
  execution_store: store,
  workflow_id: "run-abc-123"
)

result = runner.call
```

### Exact semantics

- Runner initialization requires `workflow_id` whenever `execution_store` is set.
- Before execution starts, the runner loads the stored run record and compares
  the stored fingerprint with the current fingerprint.
- Fingerprint mismatch raises `ValidationError` before any step runs.
- On successful step completion, the runner:
  1. appends the attempt trace
  2. transitions node state to `:completed`
  3. saves the successful output as reusable
- On resume, a node with reusable successful output is not executed again.
- Stored failures are auditable but never treated as reusable completed work.
- Checkpoint TTL is evaluated when loading reusable output. Expired output is
  treated as missing and the node is re-executed.
- `clear_on_completion:` is optional and defaults to `false`. The default
  preserves auditability and version history.

Minimum `FileStore` guarantees in v1:

- per-record writes use temp-file-plus-rename atomic replacement
- a crash may lose the last in-flight write, but must never expose a partially
  written readable record
- no distributed locking, lease, or multi-writer coordination guarantee is
  provided

### Fingerprinting rules

- Built-in YAML-safe steps fingerprint from canonical dumped config.
- Built-in non-YAML-safe steps must define a stable fingerprint strategy.
- `:ruby` requires explicit `resume_key:` if persistence is enabled.

### Acceptance criteria

- Successful resume skips previously completed nodes and feeds their stored values downstream.
- Stored failures do not short-circuit re-execution.
- Fingerprint mismatch is rejected before any work runs.
- Expired reusable output is ignored.
- Two runs with the same `workflow_id` but different graph structure do not silently share checkpoints.

**Status:** `implemented` | **Priority:** high

Current repo reality: checkpointing/resume is present with `ExecutionStore`,
`FileStore`, reusable output loading, durable fingerprints, TTL-aware reuse, and
`clear_on_completion:`. Future work here is mostly documentation and polish, not
missing core behavior.

---

## Feature 3: Sub-Workflow Composition

Sub-workflow is a first-class built-in step type. It executes another
`Definition` inside the parent run using the same execution model.

### Public API

```ruby
child_def = DAG::Workflow::Loader.from_hash(
  analyze: {type: :ruby, callable: ->(input) { ... }},
  summarize: {type: :ruby, depends_on: [:analyze], callable: ->(input) { ... }}
)

parent_def = DAG::Workflow::Loader.from_hash(
  fetch: {type: :exec, command: "curl ..."},
  process: {
    type: :sub_workflow,
    definition: child_def,
    depends_on: [:fetch],
    input_mapping: {fetch: :raw_data},
    output_key: :summarize
  }
)
```

YAML-safe form:

```yaml
nodes:
  process:
    type: sub_workflow
    definition_path: workflows/child.yml
    depends_on: [fetch]
    input_mapping:
      fetch: raw_data
    output_key: summarize
```

### Exact semantics

- `:sub_workflow` is a built-in step type registered by the gem.
- It accepts exactly one of `definition:` or `definition_path:`.
- `definition:` is programmatic-only.
- `definition_path:` is YAML-safe and is resolved relative to the caller.
- Parent input is transformed by `input_mapping` before the child run starts.
- Parent and child share one logical `workflow_id`.
- There is no separate child workflow record or child workflow ID in v1.
- Child runner inherits:
  - parallel strategy
  - `max_parallelism`
  - remaining deadline
  - middleware stack
  - `context`
  - `execution_store`
- Child node paths are prefixed with the parent node path.
  Example: parent node `[:process]`, child node `:summarize` becomes `[:process, :summarize]`.
- Child trace entries, durable node records, reusable outputs, version history,
  and stale markers all live under that prefixed `node_path` namespace.
- Default output is a hash of child leaf values keyed by leaf name.
- `output_key:` requires that key to be a leaf node in the child definition and returns only that leaf value.
- Maximum nesting depth defaults to `10`.

### Acceptance criteria

- Child traces are flat and namespaced by `node_path`.
- Child timeout uses remaining parent deadline, not the original workflow timeout.
- `output_key` rejects non-leaf nodes.
- Checkpoint/version records for child nodes do not collide with parent nodes.
- Child persistence uses the same logical `workflow_id` as the parent run.
- Inline `definition:` is rejected by YAML dumper.

**Status:** `partial` | **Priority:** high

Current repo reality: sub-workflows are real and heavily exercised, including
durable namespaced node paths and `definition_path:` support. This remains
`partial` because it still needs a final contract-closing pass around depth /
boundary hardening and clearer documentation of the supported semantics.

---

## Feature 4: Runner Context Injection

Context injection makes runtime application data explicit and removes the need
for process-global state.

### Public API

```ruby
runner = Runner.new(definition, context: my_context)

class MyStep
  def call(step, input, context: nil)
    ...
  end
end
```

### Exact semantics

- Runner passes `context:` only to step handlers that accept it.
- Existing handlers with `call(step, input)` continue to work.
- `:ruby` callables are invoked as:
  - `callable.call(input)` if arity is `1` or less
  - `callable.call(input, context)` if arity is `2` or more
- Built-in steps ignore context unless they later opt in.
- `context` must be thread-safe under `:threads`.
- `context` is not automatically serialized into forked children under `:processes`.
- `Runner.new(..., context: ..., parallel: :processes)` fails fast unless a
  future feature introduces explicit `context_serializer:` /
  `context_loader:` hooks.

### Acceptance criteria

- Sequential and threads modes pass context to compatible handlers.
- Processes mode raises a clear validation error at `Runner.new` if context is
  present and no explicit context-serialization strategy exists.
- Built-in steps that do not accept context still run unchanged.

**Status:** `implemented` | **Priority:** high

---

## Feature 5: Node Scheduling Constraints

Scheduling is expressed as eligibility rules on nodes plus persisted waiting
state. The synchronous runner evaluates readiness; it does not sleep.

### Public API

```ruby
Step.new(
  name: :weekly_scan,
  type: :exec,
  command: "...",
  schedule: {
    not_before: Time.parse("2026-05-01T09:00:00Z"),
    not_after: Time.parse("2026-05-01T17:00:00Z"),
    cron: "0 9 * * MON",
    ttl: 604_800
  }
)

runner = Runner.new(definition, clock: my_clock)
```

### Exact semantics

- `not_before`: node is ineligible before the timestamp. Runner records node state `:waiting`.
- `not_after`: if `clock.wall_now` is past this timestamp before completion, node transitions to `:failed` with `code: :deadline_exceeded`.
- `ttl`: reusable output older than this duration relative to `clock.wall_now` is stale and cannot satisfy resume/version lookup.
- `cron`: stored scheduling metadata only. The coordinator is responsible for invoking the runner on the relevant schedule.
- Scheduling eligibility uses `clock.wall_now`.
- Workflow deadlines, retry backoff, and duration measurements use `clock.monotonic_now`.
- The runner never sleeps waiting for `not_before`.
- A run returns `RunResult(status: :waiting, waiting_nodes: [...])` if at least one node is waiting and no runnable or failing nodes remain in this invocation.

### Acceptance criteria

- `not_before` future nodes do not emit `Success(nil)`.
- `not_after` fails deterministically before executing late work.
- `ttl` expiry causes re-execution instead of reuse.
- `cron` metadata round-trips through Loader/Dumper for YAML-safe step types.
- Scheduling tests can run against a fake clock without real sleeping.

**Status:** `partial` | **Priority:** medium

Current repo reality: `not_before`, `not_after`, `ttl`, waiting state, and cron
metadata round-trip all exist. This remains `partial` because scheduling is
implemented as runner-time eligibility plus stored metadata, but still needs a
more explicit closeout pass in the roadmap/docs.

---

## Feature 6: Versioned Step Outputs

Versioning records all successful outputs for a node over time. Resume uses the
reusable latest version; historical queries use version metadata.

### Public API

```ruby
runner = Runner.new(definition,
  execution_store: store,
  workflow_id: "pipeline-001"
)

Step.new(
  name: :analyze,
  type: :ruby,
  depends_on: [
    {from: :weekly_scan, version: :latest},
    {from: :config, version: 3},
    {from: :daily_metrics, version: :all}
  ],
  callable: ->(input) { ... }
)
```

### Exact semantics

- Version numbers are monotonically increasing integers per node starting at `1`.
- Only successful completed outputs create versions.
- `version:` may be:
  - `:latest` (default)
  - positive `Integer`
  - `:all`
- Resolved input values:
  - `:latest` -> single raw value
  - integer -> single raw value
  - `:all` -> array of raw values ordered by ascending version
- The existing `depends_on` hash shape is extended with `version:` and optional `as:`.
- For local dependencies, `version: :latest` follows normal dependency
  resolution and reusable-output lookup. It does not create a separate waiting
  state by itself.
- For local dependencies, requesting an explicit integer version that does not
  exist fails the workflow with `code: :missing_dependency_version`.
- For local dependencies, `version: :all` returns `[]` when no historical
  versions exist.
- If `as:` is omitted:
  - local dependency key defaults to `from`
  - cross-workflow dependency key defaults to `node`
- Duplicate effective input keys are validation errors.

### Acceptance criteria

- Loader/Dumper round-trip `version:` metadata.
- `:all` produces ordered arrays of raw values, not `DAG::Result` objects.
- Missing explicit local integer versions fail with `:missing_dependency_version`.
- `:all` over an empty local history returns `[]`.
- Resume always reuses the latest reusable successful version only.

**Status:** `implemented` | **Priority:** medium

Current repo reality: versioned outputs, explicit version selection,
`version: :all`, `as:`, durable history, and runnable examples/tests are all in
the repo. The implementation uses the refined runtime contract discovered during
development rather than the exact placeholder wording of the original roadmap.

---

## Feature 7: Invalidation Cascade

Invalidation marks previously completed downstream work as stale so it will be
recomputed on the next invocation.

### Public API

```ruby
DAG::Workflow.invalidate(workflow_id: "pipeline-001", node: [:weekly_scan], execution_store: store)
DAG::Workflow.stale_nodes(workflow_id: "pipeline-001", execution_store: store)
```

### Exact semantics

- Invalidating a node walks the transitive descendant closure in the current definition.
- The invalidated node itself is included if and only if it is currently `:completed`.
- Included nodes transition to `:stale`.
- Reusable outputs for stale nodes are marked `superseded: true`.
- Historical versions are retained for audit.
- On the next run, stale nodes are treated as pending work and re-executed.
- Optional `max_cascade_depth` limits traversal depth from the invalidated root.

### Acceptance criteria

- Only descendants are marked stale.
- Historical versions remain queryable after invalidation.
- Superseded outputs are never reused for resume.
- Depth limit stops propagation deterministically.

**Status:** `implemented` | **Priority:** medium

Current repo reality: invalidation is implemented, including stale-node
inspection, cascade depth limiting, nested node paths, ancestor stale
propagation for sub-workflows, and reusable-output supersession with history
preserved.

---

## Feature 8: Dynamic Graph Mutation

Graph mutation is a between-invocations operation on persisted execution plus a
new `Definition`. It is not live surgery on an in-flight in-memory runner.

### Public API

```ruby
new_definition = DAG::Workflow.replace_subtree(
  definition,
  root_node: :process,
  replacement: replacement_definition,
  reconnect: [
    {from: :summarize, to: :report, metadata: {}}
  ]
)
```

Graph primitive:

```ruby
graph.with_subtree_replaced(
  root: :process,
  replacement_graph: replacement_graph,
  reconnect: [
    {from: :summarize, to: :report, metadata: {}}
  ]
)
```

### Exact semantics

- Mutation is only legal between runner invocations.
- The replaced subtree root must not currently be `:running`.
- For v1, replacement definitions must have exactly one root unless explicit
  ingress mapping is added in a future feature.
- Incoming edges of the old root are rewired to the single root of the replacement graph.
- Each `reconnect` descriptor maps one replacement leaf to one original
  downstream node and optionally supplies replacement edge metadata.
- Multiple reconnect descriptors may target the same downstream node.
- Downstream nodes with multiple inputs keep unaffected inputs unchanged.
- Duplicate effective downstream aliases or incompatible reconnect metadata are
  validation errors.
- If the removed edges carried required metadata and reconnect descriptors do
  not recreate it explicitly, the mutation is invalid.
- Replacement must remain acyclic after reconnection.
- Persisted state for removed nodes is retained for audit but marked obsolete.
- Persisted state for downstream completed nodes reachable from the replaced
  subtree is marked stale.

### Acceptance criteria

- Replacement preserves upstream completed outputs.
- Cycle introduction is rejected before state mutation.
- Reconnected downstream nodes receive inputs from the mapped replacement
  leaves while preserving untouched inputs.
- Reconnect metadata rules are validated deterministically before state mutation.
- Old subtree state is auditable but not reusable.

**Status:** `partial` | **Priority:** medium

Current repo reality: immutable subtree replacement, impact planning,
state-application helpers, obsolete/stale transitions, running-root guards, and
file-store rerun flows are implemented. It remains `partial` because the current
mutation story is intentionally narrower than the full feature name suggests:
today it is subtree replacement between invocations, not arbitrary dynamic
graph surgery.

---

## Feature 9: Event Emission from Steps

This feature is limited to event emission from completed step attempts. Event-
triggered non-DAG activation is not part of the core gem roadmap.

### Public API

```ruby
Step.new(
  name: :monitor,
  type: :ruby,
  callable: ->(input) { ... },
  emit_events: [
    {name: :anomaly_detected, if: ->(result) { result.value[:score] > 0.8 }},
    {name: :high_priority, if: ->(result) { result.value[:priority] == :high }}
  ]
)

bus = DAG::Workflow::EventBus.new
runner = Runner.new(definition, middleware: [DAG::Workflow::EventMiddleware.new], event_bus: bus)
```

### Event structure

```ruby
Event = Data.define(:name, :workflow_id, :node_path, :payload, :emitted_at)
```

### Event bus contract

```ruby
class EventBus
  def publish(event) = nil
end
```

### Exact semantics

- Events are emitted only after the final successful step attempt.
- Event conditions inspect the final `DAG::Result` of that step attempt.
- Event emission is middleware-driven and does not modify step output.
- Middleware calls `event_bus.publish(event)` synchronously at the bus boundary.
- Event bus delivery is best-effort and non-transactional in v1.
- Failed attempts and intermediate retry failures emit no events.
- YAML support is not part of v1 because event conditions are Proc-based.
- Trigger steps and out-of-graph reactive activation are explicitly out of scope for this feature.

### Acceptance criteria

- A successful step can emit zero, one, or many events.
- Failed attempts emit no events.
- Event payload shape is stable and includes workflow ID and node path.
- `publish(event)` is called once per emitted event.
- Event emission never changes the workflow result branch.

**Status:** `implemented` | **Priority:** low

Current repo reality: `Event`, `EventBus`, `EventMiddleware`, payload/metadata
callables, retry-aware emission semantics, nested sub-workflow propagation, and
runnable examples/tests are all implemented.

---

## Feature 10: Cross-Workflow Dependencies

Cross-workflow dependencies resolve external values before a node attempt
executes. They are modeled as dependency descriptors plus a resolver hook.

### Public API

```yaml
nodes:
  analyze:
    type: ruby_script
    path: analyze.rb
    depends_on:
      - from: data_fetch
      - workflow: pipeline-a
        node: validated_output
        version: latest
        as: validated
```

```ruby
resolver = ->(workflow_id, node_name, version) {
  entry = store.load_output(workflow_id: workflow_id, node_path: [node_name], version: version)
  entry ? entry[:result] : nil
}

runner = Runner.new(definition,
  cross_workflow_resolver: resolver,
  execution_store: store,
  workflow_id: "pipeline-b"
)
```

### Exact semantics

- Cross-workflow dependency descriptors are not stored as edges in the local graph.
- Resolution occurs before the step attempt is built.
- The resolver is called with `workflow_id`, `node_name`, and `version`.
- The resolver may be positional or keyword-style.
- The resolver may return:
  - a raw value
  - a `DAG::Success`
  - a Hash shaped like a stored output entry (`{result: ...}`)
  - `nil` to signal "not yet available"
- `nil` means the node becomes `:waiting`.
- Resolver exceptions fail the workflow explicitly.
- Resolved values enter the input hash under `as:` or the default alias.
- No cross-workflow cycle detection is provided by the gem.
- The gem does not infer waitability for missing external data beyond `nil` from the resolver.

### Acceptance criteria

- Local and cross-workflow dependencies can coexist on the same node.
- Resolver `nil` yields `RunResult(status: :waiting)` when no runnable work remains.
- Resolver exceptions yield explicit workflow failure.
- Duplicate input aliases are validation errors.
- External resolution failure is surfaced as explicit workflow error, not silent skip.

**Status:** `partial` | **Priority:** low

Current repo reality: cross-workflow dependency descriptors, resolver-driven
waiting/failure behavior, loader/dumper round-trip, and runnable examples/tests
exist today. It remains `partial` because the concrete resolver contract that
landed in code is simpler and more Ruby-native than the original structured
`CrossWorkflowResolution` sketch in this document.

---

## Feature 11: Pause and Resume

Pause/resume is coordinator-driven and persisted. There is no long-lived
`RunHandle` API in the core runner.

### Public API

```ruby
store.set_pause_flag(workflow_id: "pipeline-001", paused: true)

result = Runner.new(definition,
  execution_store: store,
  workflow_id: "pipeline-001"
).call

store.set_pause_flag(workflow_id: "pipeline-001", paused: false)

result = Runner.new(definition,
  execution_store: store,
  workflow_id: "pipeline-001"
).call
```

### Exact semantics

- Pause is observed between layers only.
- A pause flag never interrupts running steps.
- If pause is observed before the next layer starts, workflow status becomes `:paused`.
- Resume is simply another `Runner#call` with the same `workflow_id`.
- Completed reusable outputs are reused on resume.
- Pause gating and resume deadlines continue to use the injected `clock`.
- Human approval is modeled as durable `:waiting` state set by the coordinator or approval middleware, not as a special in-process blocking step primitive.

### Acceptance criteria

- Pause takes effect only between layers.
- Resume does not rerun completed nodes.
- A paused workflow can later move to `:completed`, `:failed`, or `:waiting`.

**Status:** `implemented` | **Priority:** medium

---

## Feature 12: Step Middleware

Middleware is a foundational enabler, not a side feature. It is implemented
before retry, checkpointing, and event emission.

### Public API

```ruby
class LoggingMiddleware
  def call(step, input, context:, execution:, next_step:)
    log("starting #{execution.node_path.join('.')}")
    result = next_step.call(step, input, context: context, execution: execution)
    log("finished #{execution.node_path.join('.')}: #{result.success? ? 'ok' : 'fail'}")
    result
  end
end

runner = Runner.new(definition,
  middleware: [
    LoggingMiddleware.new,
    DAG::Workflow::RetryMiddleware.new,
    DAG::Workflow::CheckpointMiddleware.new
  ]
)
```

### Exact semantics

- Middleware wraps one step attempt.
- Middleware order is declaration order, first outermost.
- `next_step` must return `DAG::Result`.
- Middleware may short-circuit by returning `DAG::Result` directly.
- Middleware must not mutate `Step`.
- Milestone 0 changes the strategy boundary: the runner resolves dependency
  inputs, builds `StepExecution`, composes middleware around the core step
  call, and hands one prepared attempt callable to the strategy.
- Middleware is executed inside the strategy worker, not around graph traversal.
- The strategy executes prepared attempt callables and measures timing. It does
  not know about middleware ordering, stores, event buses, or lifecycle rules.
- The runner remains responsible for workflow traversal, dependency resolution,
  lifecycle transitions, and trace entries.

### Initial built-ins planned

- `RetryMiddleware`
- `CheckpointMiddleware`
- `EventMiddleware`
- `LoggingMiddleware` is example-only, not required as a built-in

### Acceptance criteria

- Middleware ordering is deterministic.
- Short-circuit middleware still produces valid trace/state transitions.
- Non-`DAG::Result` middleware returns are treated as contract violations.

**Status:** `implemented` | **Priority:** medium

---

## Milestone and feature summary

The tables below reflect the current repo state, not the original untouched plan.
Milestone 0 remains marked `partial` only as a bookkeeping reminder that some
foundation contracts were finished through later feature work instead of through
one isolated milestone PR.

### Milestone 0 summary

| Milestone | Scope | Status | Complexity |
|-----------|-------|--------|------------|
| 0 | `RunResult`, `ExecutionStore`, fingerprinting, `Clock`, middleware handoff | `partial` | large |
| 0a | runtime reality | most foundation pieces are landed; remaining work is contract/documentation closeout | - |

### Feature summary

| # | Feature | Priority | Status | Complexity |
|---|---------|----------|--------|------------|
| 1 | Step retry with backoff | high | `implemented` | small |
| 2 | Checkpointing and resume | high | `implemented` | medium |
| 3 | Sub-workflow composition | high | `partial` | medium |
| 4 | Runner context injection | high | `implemented` | small |
| 5 | Node scheduling constraints | medium | `partial` | medium |
| 6 | Versioned step outputs | medium | `implemented` | medium |
| 7 | Invalidation cascade | medium | `implemented` | small |
| 8 | Dynamic graph mutation | medium | `partial` | large |
| 9 | Event emission from steps | low | `implemented` | small |
| 10 | Cross-workflow dependencies | low | `partial` | medium |
| 11 | Pause and resume | medium | `implemented` | medium |
| 12 | Step middleware | medium | `implemented` | small |

## Dependency graph

```text
Milestone 0 (RunResult + ExecutionStore + fingerprinting + Clock + middleware handoff)
    |
    +--> Feature 12 (Middleware)
    |        |
    |        +--> Feature 1 (Retry)
    |        +--> Feature 2 (Checkpointing and resume)
    |        +--> Feature 9 (Event emission)
    |
    +--> Feature 4 (Context injection)
    |
    +--> Feature 3 (Sub-workflow composition)
    |
    +--> Feature 11 (Pause and resume)
    |
    +--> Feature 5 (Scheduling)
             |
             +--> Feature 6 (Versioned outputs)
                       |
                       +--> Feature 7 (Invalidation cascade)
                       +--> Feature 10 (Cross-workflow dependencies)
    |
    +--> Feature 8 (Dynamic graph mutation)
```

## Revised completion order from the current repo state

The original implementation order was useful as a bootstrap sequence, but it is
no longer the right way to think about the project. Too much has already landed.
From here, the goal is to close the partials in a deliberate order.

### Phase A: reconcile contracts with reality

1. keep this roadmap aligned with the codebase
2. make README, examples, and feature-status claims agree
3. explicitly document where the shipped contract differs from the original sketch
   - especially cross-workflow resolver semantics
   - and the narrower current scope of dynamic mutation

### Phase B: close the highest-value partials

1. Feature 3: sub-workflow composition
   - enforce and document any remaining nesting/depth limits
   - re-check deadline inheritance and edge-case validation coverage
   - make the supported contract explicit instead of implied by tests
2. Feature 5: scheduling constraints
   - decide whether this is effectively done after docs cleanup
   - or land the small remaining gaps and promote it to `implemented`
3. Feature 10: cross-workflow dependencies
   - either bless the simpler resolver contract that shipped
   - or add a thin normalization layer if the original structured contract is still preferred
4. Feature 8: dynamic graph mutation
   - document that the implemented slice is subtree replacement between invocations
   - decide whether the roadmap should stop there for v1 or grow beyond it in a later phase

### Phase C: milestone closeout

1. revisit Milestone 0 and mark it complete only after the remaining partial
   contracts are documented and intentionally accepted
2. remove stale "not-started" assumptions from companion docs and planning notes
3. treat new feature work as optional only after the current contract is coherent

### Practical next-step recommendation

If choosing just one next engineering slice, do this:

1. finish the documentation/status reconciliation
2. then take a narrow sub-workflow hardening PR

That order keeps the roadmap trustworthy and uses the next code change to close a
real remaining gap instead of starting yet another side branch of functionality.

## Explicit non-goals for this roadmap

- A built-in cron daemon or worker scheduler
- Distributed multi-machine execution
- Event-triggered non-DAG activation inside the core DAG graph model
- Automatic serialization of arbitrary Ruby objects used as context
- Silent reuse of non-fingerprintable `:ruby` steps across process restarts

## Possible companion docs

- `durable-state-and-filestore.md`
- `dynamic-graph-mutation.md`
- `temporal-execution-and-versioning.md`
