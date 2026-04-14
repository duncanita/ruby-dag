# Changelog

## 0.4.0

### Added

- **Declarative `run_if` DSL** for YAML workflows. Conditions use logical
  operators (`all`, `any`, `not`) and leaf predicates on direct dependencies
  (`from`, `status`, `value` with `equals`/`in`/`present`/`nil`/`matches`).
  Callable `run_if` continues to work for programmatic workflows.
- `Condition` module: normalize, validate, evaluate, dump, rename_from.
- `Validator` module: checks `run_if` conditions against graph structure.
- `Graph#each_successor`: zero-alloc iteration over successors, symmetric
  with `each_predecessor`.
- `Definition#replace_step` rewrites declarative `run_if` `:from` references
  when renaming nodes.
- `Loader` rejects blank `run_if:` (null/empty) instead of silently treating
  it as "no condition".
- `Condition.normalize` rejects non-YAML-safe values in `equals`/`in`
  predicates and malformed operands (nil/callable) inside logical operators.

### Fixed

- **EINTR in `Steps::Exec#drain_pipes`**: `read_nonblock(exception: false)`
  does not suppress `Errno::EINTR`. Under the `Threads` strategy with
  concurrent `:exec` steps, SIGCHLD from a sibling child could crash a
  healthy step. Now rescued with retry, matching the existing fix in
  `Parallel::Processes`.
- **`empty_child_payload` diagnostics**: the error now includes the child's
  exit status ("killed by signal 9", "exited 1") instead of the opaque
  "exited without writing a payload".
- `run_if` is canonicalized once at `Step` construction. Ruby entry points
  (`Step.new`, `Loader.from_hash`) treat `run_if: nil` as omitted, while YAML
  keeps rejecting blank `run_if:`.
- `Condition.evaluate` handles callable conditions instead of crashing with
  `NoMethodError`.

### Documentation

- FileRead/FileWrite document their path policy: no sandboxing, caller
  responsible for validation with untrusted definitions.
- README documents the declarative `run_if` DSL, condition combinators,
  and `workflow_dead_end` failure mode.

## 0.3.1

- Removed Ractors strategy (Ruby 4.0 deadlock detector incompatibility).
- Consolidated `KILL_GRACE_SECONDS` as single source of truth.
- 100% line and branch coverage enforcement.
