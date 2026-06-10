# ruby-dag v1.0.1 - Codex Review

Reviewed on: 2026-05-02  
Scope: repository state on disk, not a clean release tag. The working tree had
local edits and untracked review artifacts at review time.

This is an honest engineering review of `ruby-dag` as a deterministic Ruby DAG
execution kernel. It is not a marketing review.

## Verdict

`ruby-dag` is a solid kernel for the scope it declares: deterministic workflow
execution over immutable definitions, explicit ports, durable event semantics,
retry/resume behavior, structural mutation, and an abstract effect ledger. It
is not a general-purpose workflow platform, and it should not try to become one
inside this gem.

The project is stronger than average because its hard constraints are enforced
in code and tests, not just described in prose:

- zero runtime dependencies in the gemspec;
- Ruby `>= 3.4`;
- explicit seven-port `Runner`;
- no `Thread`, `Ractor`, `Mutex`, `Queue`, `Process.spawn`, `system`, or
  backticks in `lib/dag/**`;
- immutable public value objects via `Data.define` and defensive frozen copies;
- shared storage contract specs for adapter behavior.

The main risk is not sloppy code. The main risk is scope gravity. The storage
port and memory storage state have become the real center of the system. If the
next phases keep adding behavior to that boundary, the library will drift from
"small deterministic kernel" to "workflow engine database contract", with a
large adapter tax for every consumer.

## Verification

Commands run during review:

```bash
bundle exec rake
bundle exec ruby scripts/production_readiness.rb --fast --duration 5 --progress-interval 2
```

Observed results:

- `bundle exec rake`: 515 tests, 39885 assertions, 0 failures, 0 errors.
- Standard/RuboCop custom cops: clean.
- YARD: 99.08% documented.
- Production readiness fast probe: pass after 5 seconds.

I also checked runtime anti-patterns with repository search. No forbidden
thread/ractor/process primitives or `attr_accessor` were found under
`lib/dag/**`. Runtime `require` usage is stdlib-only: `securerandom`, `digest`,
and `json`.

## Vision

Your vision is mostly correct, but not all parts have the same truth value.

### Zero external dependencies

Correct for the kernel. This is one of the best decisions in the project. It
keeps the public gem easy to audit, easy to embed, and hard to accidentally
turn into a framework.

Do not extend this dogma to durable infrastructure. SQLite, PostgreSQL, Redis,
HTTP clients, queue systems, and observability integrations belong outside this
gem. The current decision to keep SQLite outside the zero-dependency kernel is
right.

### Monads

Correct if kept small. `Success` / `Failure` as a `Result` pair is useful:
`and_then`, `map`, `recover`, `unwrap!` are enough.

It is also correct that `Waiting` is not part of `DAG::Result`. Waiting is a
state-machine outcome, not just a value-level failure or success. Making it a
third monadic branch would make the public API look elegant while hiding an
important runtime distinction.

Do not add a large monadic vocabulary unless the project itself uses it. More
methods would make the library less Ruby-like without clearly improving the
kernel.

### Immutable data types

Correct at the public and pure-kernel boundaries. `Data.define` plus
`DAG.frozen_copy` is a good fit for Ruby 3.4.

The current exception is also correct: `DAG::Adapters::Memory::StorageState` is
mutable. Pretending storage internals are immutable would add ceremony and
probably bugs. The important rule is that mutation stays behind the port and
callers never receive live mutable references.

### Copy-on-write for future concurrency

Partly correct. Copy-on-write and frozen values reduce aliasing, make execution
more deterministic, and make future concurrency less dangerous.

They do not give you concurrency by themselves. Future concurrency will depend
on storage atomicity, compare-and-set boundaries, leases, and durable adapter
behavior. The project already recognizes this in methods like
`prepare_workflow_retry`, `transition_workflow_state(event:)`,
`append_revision_if_workflow_state`, and effect lease operations.

### Balance between OOP and functional programming

This is one of the better parts of the design. The split is natural:

- OOP for ports, adapters, runner, dispatcher, mutation service;
- functional/value style for definitions, graph transformations, results, and
  effect intents;
- explicit state transitions instead of hidden object mutation.

That is idiomatic Ruby. It is not "functional Ruby cosplay".

### Ruby idiomatic

Mostly yes. Keyword arguments, small objects, `Data.define`, block builders,
explicit error classes, and straightforward service objects are idiomatic.

The main place where idiomatic Ruby is at risk is not the current code, but the
future direction: if monads, validation helpers, or storage extensions become
too generic, the project will start to feel like a private framework.

### DRY

The DRY direction is good: `DAG::Validation` and `DAG.frozen_copy` remove
boring repeated boundary code.

But DRY should not hide contract logic. In this project, explicitness matters
more than clever reuse. The storage contract, runner transitions, and effect
lease semantics should stay readable even if that means some local repetition.

## What Works Well

### The kernel has real boundaries

`DAG::Runner` requires all seven dependencies explicitly:

- `storage`
- `event_bus`
- `registry`
- `clock`
- `id_generator`
- `fingerprint`
- `serializer`

There are no hidden singleton defaults in `Runner.new`. This makes tests,
durable adapters, and future host integration much cleaner.

Reference: `lib/dag/runner.rb:54`.

### Crash-resume semantics are treated seriously

The project does not hand-wave durability. The runner and storage contract
separate attempt commit, workflow terminal transition, retry preparation,
mutation revision append, and effect completion into explicit atomic
boundaries.

Good examples:

- `commit_attempt(..., effects: [])` commits result, node state, event, and
  effect reservations together.
- `transition_workflow_state(..., event:)` closes the crash window between a
  terminal workflow state and its terminal event.
- `prepare_workflow_retry` owns the retry-budget check and reset operation.
- `complete_effect_succeeded` / `complete_effect_failed` close the mark/release
  crash gap for effects.

This is the right kind of complexity. It exists because the failure modes are
real.

### The effect design is abstract in the right way

The kernel reserves effect intents and coordinates dispatch, but concrete side
effects stay in host handlers. That is the right split.

The public promise in the README is also honest:

```text
exactly-once durable effect intent reservation
+ at-most-once successful effect recording per (type, key)
+ lease-protected dispatch
+ effectively-once external side effects through host handlers
```

The first three are kernel concerns. The last one belongs to consumers. Good.

### Tests are not superficial

The suite is broad for a small gem:

- graph behavior and fuzzing;
- zero runtime dependencies;
- public require;
- custom RuboCop cops;
- runner behavior;
- retry and resume;
- effect value objects;
- effect dispatcher;
- shared storage contract;
- mutation service and stale revision behavior;
- crashable storage tests.

The shared storage contract under `spec/support/storage_contract/**` is
especially important. Without that, the storage port would just be prose.

### The project is honest about memory adapters

The memory adapters are documented as single-process. That prevents a common
Ruby mistake: pretending an in-memory adapter is a cheap substitute for durable
coordination.

## Findings

### 1. Medium-high: the storage port is now the real kernel

`lib/dag/ports/storage.rb` is canonical, but it is large. It covers:

- workflow rows;
- definition revisions;
- node states;
- attempts;
- durable events;
- crash resume;
- workflow retry;
- mutation CAS;
- effect reservation;
- effect lookup;
- effect claim leases;
- effect completion;
- waiting-node release;
- batched predecessor result lookup.

Reference: `lib/dag/ports/storage.rb:23`.

This is coherent, but expensive. A durable adapter must implement a lot before
it is useful. That can slow adoption and make the first non-memory adapter a
major project rather than a small integration.

I would not split the port casually now, because the repo rules correctly say
the port shape is canonical. But I would freeze the growth of this interface
hard. New behavior should have to prove it cannot be expressed by existing
atomic boundaries.

Concrete proposal:

- Add an adapter capability matrix in docs: "runner core", "resume", "mutation",
  "effects", "dispatcher".
- Keep the canonical port, but document which method groups are required for
  which public feature.
- Before adding another storage method, require a short contract note explaining
  the crash or stale-read window it closes.

### 2. Medium: effect idempotency conflicts can leave workflows operationally stuck

The storage contract correctly rolls back `commit_attempt` if effect
reservation detects a fingerprint conflict. The test asserts this explicitly:
after `DAG::Effects::IdempotencyConflictError`, the second attempt remains
`:running`, the node remains `:running`, no event is appended, and no effect
link is created.

Reference: `spec/support/storage_contract/effects.rb:87`.

That is atomic and defensible at the storage layer. But at the runner layer it
is harsh. A deterministic step that reuses the same `(type, key)` with a
different payload can repeatedly hit the same conflict. Resume can abort the
running attempt and reset the node, but the next run will likely produce the
same conflict again.

This is not data corruption. It is an operational dead end.

Concrete proposal:

- In `Runner`, catch `DAG::Effects::IdempotencyConflictError` around
  `commit_attempt` for step outcomes with effects.
- Convert it into a non-retriable node failure and workflow failure using the
  same durable event path as normal failures.
- Keep the storage-level rollback guarantee as-is.
- Add a runner spec proving the workflow ends in `:failed` with a structured
  error payload instead of leaking a `:running` node.

This preserves the effect safety invariant while giving operators a terminal,
inspectable workflow state.

### 3. Medium: public value-object validation is uneven

Some public values validate aggressively. Others trust callers more than the
contract implies.

Examples:

- `DAG::StepInput` validates `metadata` JSON safety, but not that `context` is
  a `DAG::ExecutionContext`, that `node_id` is symbol/string-like, or that
  `attempt_number` is positive.
  Reference: `lib/dag/step_input.rb:27`.
- `DAG::Event` validates `type` and `payload`, but not `workflow_id`,
  `revision`, `node_id`, `attempt_id`, `seq`, or `at_ms`.
  Reference: `lib/dag/event.rb:38`.
- `DAG::RuntimeProfile` validates durability and retry counts, but not
  `event_bus_kind`.
  Reference: `lib/dag/runtime_profile.rb:40`.
- `DAG::RunResult` validates JSON safety for `outcome` and `metadata`, but not
  `state` or `last_event_seq`.
  Reference: `lib/dag/run_result.rb:27`.

This does not currently break the runner, because the runner constructs these
objects correctly. But these are public API objects. If the project advertises
them as contract values, they should reject malformed values consistently.

Concrete proposal:

- Add narrow validation helpers where missing:
  - optional nonnegative integer;
  - workflow id string;
  - optional node id;
  - workflow state enum;
  - event bus kind enum or documented opaque symbol.
- Tighten `StepInput`, `Event`, `RunResult`, and `RuntimeProfile`.
- Add tests in `spec/r1/types_validation_test.rb`.

This is the sort of fix that pays off later when external adapters and hosts
start constructing values directly.

### 4. Medium-low: `Memory::StorageState` is doing too much

`lib/dag/adapters/memory/storage_state.rb` is about 760 lines and owns every
mutable in-memory concern.

Reference: `lib/dag/adapters/memory/storage_state.rb:12`.

The design reason is valid: keep mutation in one allowed place and make the
facade return frozen copies. But the file now contains multiple subsystems:

- workflow lifecycle;
- revision append;
- attempts;
- event log;
- effect ledger;
- lease claim/mark;
- waiting-node release;
- retry reset;
- internal validations.

This is still manageable today. It will become brittle if more features land in
the same module.

Concrete proposal:

- Keep the public `DAG::Adapters::Memory::Storage` facade unchanged.
- Split internal implementation by concern under `lib/dag/adapters/memory/`,
  for example lifecycle, attempts, effects, and events.
- Preserve one mutable state hash and one public facade.
- Do this as a no-behavior-change refactor only after the next patch-level
  correctness work, not during feature work.

### 5. Medium-low: large graph builder exists but is not consistently used

`DAG::Workflow::Definition::Builder` exists specifically for bulk construction.

Reference: `lib/dag/workflow/definition/builder.rb:7`.

But `scripts/production_readiness.rb` still builds large scenarios through the
immutable chain API:

Reference: `scripts/production_readiness.rb:770`.

That makes the performance probe less representative of the intended fast path
and pays avoidable copy-on-write cost while generating test graphs.

Concrete proposal:

- Update production readiness large-graph scenarios to use
  `DAG::Workflow::Definition::Builder`.
- Keep the chainable API in README for small examples.
- Add one focused test that the builder and chain API produce equivalent
  definitions for a simple graph.

This respects the immutable public model while using the mutable-local builder
where it was meant to be used.

### 6. Low: stale untracked review artifacts can mislead future work

There is an untracked `REVIEW.md` in the repository root. Its content appears
to describe an older version of the project with `Exec`, parallel strategies,
file read/write steps, and other code that is not part of the current kernel.

Reference: `REVIEW.md:1`.

This is not a runtime bug. It is review hygiene. If a future agent or engineer
reads that file first, they will form the wrong mental model.

Concrete proposal:

- Delete it if it is obsolete.
- Or move it under a historical notes directory with a clear "obsolete" header.
- Do not leave it in root with the same apparent authority as `CONTRACT.md`.

## Non-Issues

### `Waiting` not being a monad is correct

It may look asymmetric that `Success` and `Failure` include `DAG::Result` while
`Waiting` does not. That is the right choice. Waiting is a workflow parking
state with storage implications; treating it like a normal result value would
make the runtime less explicit.

### The mutable memory adapter is acceptable

The vision says immutable data and copy-on-write. It does not require an
immutable in-memory database. `StorageState` mutating hashes internally is fine
because the port boundary protects callers from shared mutable state.

### No internal threads is a strength, not a weakness

The kernel should not run its own scheduler. Deterministic execution against
ports is the point. Parallel dispatch, durable workers, and concrete external
systems belong in hosts or adapters.

## Suggested Priority

### v1.0.2 candidate fixes

1. Convert effect idempotency conflicts in `Runner` into durable terminal
   workflow failures instead of leaving the workflow operationally stuck.
2. Tighten public value-object validation for `StepInput`, `Event`,
   `RunResult`, and `RuntimeProfile`.
3. Update production readiness large-graph scenarios to use
   `Definition::Builder`.
4. Remove or quarantine obsolete root-level review artifacts.

### Later refactors

1. Split `Memory::StorageState` internally by concern without changing the
   public facade.
2. Add adapter capability documentation for the storage port.
3. Keep resisting new storage methods unless they close a concrete atomicity or
   crash-recovery hole.

## Final Assessment

The project is good. Not "good for a personal project"; good in the stricter
sense that the core constraints are visible, tested, and mostly enforced.

The vision is valid, with one correction: copy-on-write is not a concurrency
strategy. It is a discipline that makes concurrency less dangerous once the
real concurrency control exists in storage.

The next danger is not that the code becomes messy. The next danger is that the
contract becomes too large to implement comfortably. Keep the kernel small,
make every new atomic boundary justify itself, and push concrete infrastructure
outside the gem.

