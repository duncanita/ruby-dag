# ruby-dag benchmarks

_Generated 2026-04-07 22:59:55 UTC_

| Field | Value |
|---|---|
| Ruby | `ruby 3.3.11 (2026-03-26 revision 1f2d15125a) [arm64-darwin25]` |
| Platform | `darwin25 (arm64)` |
| Logical cores | 14 |
| `max_parallelism` | 8 |
| Runs per cell | 3 (median reported) |

All cells are wall-clock medians. Lower is better.

## Shape: `fan_out`

All N steps in a single topological layer (maximum parallelism opportunity).

### N = 16 steps

**IO-bound (sleep 20ms)**

| Strategy | Time | Speedup vs `:sequential` |
|---|---|---|
| `:sequential` | 471.2ms | 1.00× (baseline) |
| `:threads` | 64.2ms | 7.34× |
| `:processes` | 62.0ms | 7.61× |

**CPU-bound (fib(22) in pure Ruby)**

| Strategy | Time | Speedup vs `:sequential` |
|---|---|---|
| `:sequential` | 22.4ms | 1.00× (baseline) |
| `:threads` | 18.8ms | 1.19× |
| `:processes` | 10.4ms | 2.16× |


### N = 64 steps

**IO-bound (sleep 20ms)**

| Strategy | Time | Speedup vs `:sequential` |
|---|---|---|
| `:sequential` | 1.93s | 1.00× (baseline) |
| `:threads` | 228.7ms | 8.42× |
| `:processes` | 235.3ms | 8.19× |

**CPU-bound (fib(22) in pure Ruby)**

| Strategy | Time | Speedup vs `:sequential` |
|---|---|---|
| `:sequential` | 76.3ms | 1.00× (baseline) |
| `:threads` | 74.6ms | 1.02× |
| `:processes` | 35.8ms | 2.13× |


## Shape: `chain`

N steps in N sequential layers (no parallelism possible — measures per-step overhead).

### N = 16 steps

**IO-bound (sleep 20ms)**

| Strategy | Time | Speedup vs `:sequential` |
|---|---|---|
| `:sequential` | 474.0ms | 1.00× (baseline) |
| `:threads` | 480.5ms | 0.99× |
| `:processes` | 510.2ms | 0.93× |

**CPU-bound (fib(22) in pure Ruby)**

| Strategy | Time | Speedup vs `:sequential` |
|---|---|---|
| `:sequential` | 24.9ms | 1.00× (baseline) |
| `:threads` | 19.2ms | 1.30× |
| `:processes` | 33.3ms | 0.75× |


### N = 64 steps

**IO-bound (sleep 20ms)**

| Strategy | Time | Speedup vs `:sequential` |
|---|---|---|
| `:sequential` | 1.93s | 1.00× (baseline) |
| `:threads` | 1.94s | 0.99× |
| `:processes` | 2.03s | 0.95× |

**CPU-bound (fib(22) in pure Ruby)**

| Strategy | Time | Speedup vs `:sequential` |
|---|---|---|
| `:sequential` | 75.7ms | 1.00× (baseline) |
| `:threads` | 73.9ms | 1.02× |
| `:processes` | 134.1ms | 0.56× |


## Shape: `mixed`

ceil(N/4) layers of width 4 (realistic middle ground).

### N = 16 steps

**IO-bound (sleep 20ms)**

| Strategy | Time | Speedup vs `:sequential` |
|---|---|---|
| `:sequential` | 480.3ms | 1.00× (baseline) |
| `:threads` | 124.4ms | 3.86× |
| `:processes` | 122.7ms | 3.91× |

**CPU-bound (fib(22) in pure Ruby)**

| Strategy | Time | Speedup vs `:sequential` |
|---|---|---|
| `:sequential` | 24.1ms | 1.00× (baseline) |
| `:threads` | 19.1ms | 1.26× |
| `:processes` | 15.8ms | 1.53× |


### N = 64 steps

**IO-bound (sleep 20ms)**

| Strategy | Time | Speedup vs `:sequential` |
|---|---|---|
| `:sequential` | 1.91s | 1.00× (baseline) |
| `:threads` | 493.8ms | 3.86× |
| `:processes` | 498.1ms | 3.83× |

**CPU-bound (fib(22) in pure Ruby)**

| Strategy | Time | Speedup vs `:sequential` |
|---|---|---|
| `:sequential` | 76.3ms | 1.00× (baseline) |
| `:threads` | 74.5ms | 1.02× |
| `:processes` | 59.9ms | 1.27× |


---

## Methodology

* Each cell is the **median of 3 runs** of the same workflow definition.
* Wall-clock only (`Process.clock_gettime(CLOCK_MONOTONIC)`).
* `max_parallelism` = `DAG::Workflow::Runner::DEFAULT_MAX_PARALLELISM` (`[Etc.nprocessors, 8].min`).
* IO-bound workload: `exec` steps running `sleep 0.02`. CPU-bound: `:ruby` steps computing naive recursive `fib(22)`.
* `:processes` pays a per-step `fork()` cost; expect it to lose at small N and win at large N.
* `:threads` releases the GVL in `sleep` / `Process.spawn` so it scales on IO-bound; on CPU-bound it serializes through the GVL.

Reproduce:

```sh
ruby script/benchmark.rb --out benchmarks/$(date +%Y-%m-%d).md
```
