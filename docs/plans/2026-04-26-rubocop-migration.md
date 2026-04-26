# RuboCop Migration Plan

Goal: make `bundle exec rubocop` the full style/static-analysis gate, while
keeping the current `bundle exec rake` gate green during the migration.

## Current State

- `bundle exec standardrb` is green and remains the active style gate.
- Custom DAG cops are configured in `.rubocop.yml` and pass when run with:
  `bundle exec rubocop --only DAG/NoThreadOrRactor,DAG/NoMutableAccessors,DAG/NoInPlaceMutation,DAG/NoExternalRequires`.
- Full `bundle exec rubocop` currently reports baseline style/metrics offenses
  because the repo has not been normalized to RuboCop defaults.

## Plan

1. Decide whether the final house style is Standard-compatible RuboCop or
   vanilla RuboCop. Do not mix both as independent formatters long-term.
2. Add an explicit RuboCop baseline configuration for metrics that are noisy
   for tests and storage contract helpers.
3. Autocorrect low-risk layout/string/hash-spacing offenses in one mechanical
   commit.
4. Review non-autocorrect metrics offenses manually, preferring focused
   `Exclude` entries for tests over churny helper refactors.
5. Change `Rakefile` from `standardrb` to the agreed RuboCop task only after
   `bundle exec rubocop` is green.
