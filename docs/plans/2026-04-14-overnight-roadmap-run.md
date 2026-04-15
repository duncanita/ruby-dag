# Overnight Roadmap Run Plan

> For Hermes: execute this as a chained-branch implementation run, not as one giant branch. Keep each branch narrow, testable, and reviewable.

## Goal

Implement the first safe slice of the updated ROADMAP.md during an overnight autonomous run using chained branches, with strong planning and review discipline.

## Model policy

- Planning / orchestration: OpenAI GPT-5.4 with xhigh effort if available
- Primary code generation: Kimi
- Challenger implementation on selected branches: MiniMax M2.7
- Review / branch judgment: OpenAI GPT-5.4 with xhigh effort if available

## Branch strategy

All branches chain from the previous one. Do not skip ahead.

1. `ric/roadmap-01-runresult`
2. `ric/roadmap-02-clock`
3. `ric/roadmap-03-strategy-handoff`
4. `ric/roadmap-04-step-middleware`
5. `ric/roadmap-05-context-injection`
6. `ric/roadmap-06-retry`

Base branch: `main` at commit `5ef8eb5`

## Hard rules

- Do not attempt checkpointing, sub-workflows, versioned outputs, cross-workflow dependencies, or dynamic graph mutation in this run.
- Do not create a mega-refactor branch.
- Every branch must end with green tests or explicit stop.
- If a branch fails acceptance, stop the chain there.
- Prefer preserving current public behavior unless the roadmap explicitly requires a change.
- Make the smallest viable implementation that satisfies the branch scope.
- Commit only after tests pass.

## Stop conditions

Stop immediately if any of the following happens:

- Full test suite fails and the cause is not isolated within 20 minutes of focused debugging
- The branch requires unplanned expansion into persistence, sub-workflows, or versioning
- The public API shape becomes unclear enough that implementation would require inventing new roadmap semantics
- Two competing implementations both feel wrong or unstable after review
- A refactor would touch too many files without a clear payoff

When stopping:
- leave the repo on the current branch
- keep any useful notes in the final summary
- do not continue to the next branch

## Standard verification commands

Run from repo root:

```bash
bundle exec rake test
bundle exec rake
```

If a branch only needs targeted verification during development, use focused tests first, but before commit always run at least:

```bash
bundle exec rake test
```

Preferred final verification per branch:

```bash
bundle exec rake
```

## Standard branch workflow

For each branch:

1. Checkout parent branch
2. Create the new branch
3. Read ROADMAP.md and the relevant implementation notes in this plan
4. Plan the exact code changes
5. Implement with Kimi
6. If this branch is challenger-enabled, also produce an alternative implementation idea with MiniMax M2.7 before finalizing
7. Review with GPT-5.4 xhigh
8. Run tests
9. Commit
10. Summarize what changed, what was intentionally left out, and whether the next branch is safe to start

## Branch-by-branch plan

---

## Branch 01: `ric/roadmap-01-runresult`

### Purpose

Introduce workflow-level `RunResult` as the first foundation without yet pulling in persistence.

### Scope

- Add a `RunResult` immutable value object in the workflow layer
- Change `Runner#call` to return `RunResult` instead of using top-level `Success` / `Failure` as the workflow wrapper
- Preserve step-level `DAG::Result` unchanged
- Preserve existing step outputs, trace capture, and failure payload semantics as much as possible
- Add or update tests to lock the new contract

### Out of scope

- ExecutionStore
- middleware
- clock
- retry
- any persistence

### Acceptance

- `Runner#call` returns `RunResult`
- `RunResult.status` is `:completed` or `:failed` for current behavior
- `RunResult.outputs` contains per-node `DAG::Result`
- `RunResult.trace` still works
- `RunResult.error` is workflow-level only
- Existing runner semantics remain otherwise stable
- Tests are green

### Challenger mode

Yes: use MiniMax M2.7 to propose an alternative API shape internally if useful, but choose one final implementation only.

### Commit message

`feat: introduce workflow-level RunResult`

---

## Branch 02: `ric/roadmap-02-clock`

### Purpose

Introduce injected time abstraction cleanly before deeper runtime changes.

### Scope

- Add `Clock` protocol/value object with `wall_now` and `monotonic_now`
- Thread it through current timeout and duration paths where appropriate
- Avoid changing behavior beyond replacing direct time calls with clock usage
- Add fake-clock-friendly tests where reasonable

### Out of scope

- scheduling
- retry behavior changes
- persistence

### Acceptance

- Existing timeout behavior remains correct
- Current duration/timing logic still works
- Tests can exercise time-dependent behavior without real sleeping where applicable
- No public scheduling feature is introduced yet

### Challenger mode

Yes: MiniMax M2.7 can challenge the clock integration shape if the injection surface is small and reviewable.

### Commit message

`feat: add injected workflow clock`

---

## Branch 03: `ric/roadmap-03-strategy-handoff`

### Purpose

Move from direct strategy-owned step execution to runner-prepared attempt invocation.

### Scope

- Refactor the runner so it prepares one attempt invoker per task
- Strategies should execute prepared attempt callables and report timing
- Keep graph traversal and lifecycle concerns in the runner
- Do not fully implement middleware yet, but create the boundary needed for it

### Out of scope

- retry
- checkpointing
- event emission
- context injection behavior changes beyond what is required by the new handoff

### Acceptance

- Strategies no longer own direct `executor_class.new.call(step, input)` orchestration in the old shape
- Timing behavior still works
- Tests are green
- The new boundary is simple enough to support middleware next

### Challenger mode

No. Use one implementation path and review hard.

### Commit message

`refactor: move step attempt handoff into runner`

---

## Branch 04: `ric/roadmap-04-step-middleware`

### Purpose

Introduce middleware as a real extension point on top of the new handoff.

### Scope

- Add middleware support around a single step attempt
- Enforce declaration order, outermost-first semantics
- Enforce `DAG::Result` contract on middleware returns
- Support short-circuiting
- Add focused tests for ordering and violations

### Out of scope

- retry logic itself
- event middleware
- checkpoint middleware

### Acceptance

- Middleware wraps one attempt cleanly
- Ordering is deterministic
- Short-circuit returns work
- Bad middleware returns fail clearly
- Strategies remain agnostic to middleware ordering and workflow lifecycle

### Challenger mode

No. Keep this branch single-path and conservative.

### Commit message

`feat: add step middleware execution model`

---

## Branch 05: `ric/roadmap-05-context-injection`

### Purpose

Add context injection now that middleware and runner boundaries are cleaner.

### Scope

- Add `context:` support for compatible handlers
- Preserve backward compatibility for handlers that only accept `(step, input)`
- Support `:ruby` callables according to roadmap arity rules
- Fail fast in `Runner.new` when `context` is used with `parallel: :processes`

### Out of scope

- explicit process serializer/loader hooks
- context persistence

### Acceptance

- Sequential and threads modes pass context where supported
- Old handlers still work unchanged
- Process mode with context fails at initialization
- Tests are green

### Challenger mode

Yes: MiniMax M2.7 may suggest an alternative dispatch compatibility layer.

### Commit message

`feat: add runner context injection`

---

## Branch 06: `ric/roadmap-06-retry`

### Purpose

Implement roadmap retry as the first real middleware-based feature.

### Scope

- Add `RetryMiddleware`
- Support `max_attempts`, `retry_on`, and backoff modes needed by the roadmap
- Use monotonic clock for backoff budgeting
- Keep retry inside the same worker slot
- Emit one trace entry per attempt
- Mark retried attempts appropriately if trace supports it at this stage; if not, add the minimal extension needed

### Out of scope

- persistence-backed retry state
- checkpointing
- scheduling

### Acceptance

- Retryable failures retry up to the configured limit
- Non-matching failures do not retry
- Workflow deadline still constrains retry chains
- Final result is correct after success or exhaustion
- Tests are green

### Challenger mode

No. Use one implementation and strong review.

### Commit message

`feat: add retry middleware with backoff`

---

## Morning review checklist

When the overnight run ends, review in this order:

1. Did the chain stop at the right place?
2. Are branch scopes still clean?
3. Are tests green on each branch?
4. Is branch 03 genuinely simpler for branch 04, or did it over-refactor?
5. Does branch 06 feel like roadmap retry rather than ad hoc retry glue?
6. Is there any hidden drift toward persistence or sub-workflow complexity?

## Final expected outcome

Best case:
- 4 to 6 clean chained branches
- green tests on each completed branch
- a stable new runtime foundation for later durable features

Acceptable partial success:
- 2 to 4 strong branches completed
- chain stops before a risky branch rather than forcing bad code

Bad outcome to avoid:
- one oversized branch
- unclear API drift
- broken tests left unresolved
- accidental partial implementation of later roadmap features
