# ruby-dag — Ruby PORO DAG library (zero runtime deps, Ruby 3.4+)
#
# Common commands:
#   just check     - Full gate (test + standard + rubocop + yard), same as CI
#   just test      - Run Minitest specs (optionally a single file)
#   just lint      - Standard style + custom DAG cops
#   just format    - Auto-fix style with standardrb
#
# See 'just --list' for all available commands

# Show available commands
default:
    @just --list

# Install dependencies
install:
    bundle install

# Run the full gate: test + standardrb + rubocop + yard (same as `bundle exec rake`)
check:
    bundle exec rake

# Run Minitest specs; pass a path to run a single test file
test PATH="":
    bundle exec rake test {{ if PATH == "" { "" } else { "TEST=" + PATH } }}

# Alias for test
test-unit PATH="": (test PATH)

# Run tests with the SimpleCov coverage gate (100% line / 90% branch)
coverage:
    bundle exec rake coverage

# Lint: Standard style + custom DAG cops (NoThreadOrRactor, NoInPlaceMutation, ...)
lint:
    bundle exec standardrb
    bundle exec rubocop --display-cop-names

# Auto-fix style violations
format:
    bundle exec standardrb --fix

# YARD documentation gate (no warnings + >= 99% documented)
docs:
    bundle exec rake yard

# Mutation-test subjects changed since main (or SINCE)
mutant SINCE="main":
    MUTANT_SINCE={{SINCE}} bundle exec rake mutant:changed

# Install pre-commit hooks (pre-commit + commit-msg)
pre-commit-install:
    pre-commit install --install-hooks
    pre-commit install --hook-type commit-msg

# Run pre-commit on all files
pre-commit-run:
    pre-commit run --all-files

# Run pre-commit on staged files only
pre-commit-staged:
    pre-commit run
