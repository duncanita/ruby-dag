# ruby-dag benchmarks

_Generated 2026-04-07 22:55:53 UTC_

| Field | Value |
|---|---|
| Ruby | `ruby 3.2.11 (2026-03-27 revision 5483bfc1ae) [arm64-darwin25]` |
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
| `:sequential` | 489.6ms | 1.00× (baseline) |
| `:threads` | 62.2ms | 7.87× |
| `:processes` | 63.0ms | 7.77× |

**CPU-bound (fib(22) in pure Ruby)**

| Strategy | Time | Speedup vs `:sequential` |
|---|---|---|
| `:sequential` | 20.9ms | 1.00× (baseline) |
| `:threads` | 17.6ms | 1.19× |
| `:processes` | 11.1ms | 1.88× |


### N = 64 steps

**IO-bound (sleep 20ms)**

| Strategy | Time | Speedup vs `:sequential` |
|---|---|---|
| `:sequential` | 1.90s | 1.00× (baseline) |
| `:threads` | 228.2ms | 8.33× |
| `:processes` | 236.1ms | 8.05× |

**CPU-bound (fib(22) in pure Ruby)**

| Strategy | Time | Speedup vs `:sequential` |
|---|---|---|
| `:sequential` | 67.8ms | 1.00× (baseline) |
| `:threads` | 69.6ms | 0.97× |
| `:processes` | 37.7ms | 1.80× |


## Shape: `chain`

N steps in N sequential layers (no parallelism possible — measures per-step overhead).

### N = 16 steps

**IO-bound (sleep 20ms)**

| Strategy | Time | Speedup vs `:sequential` |
|---|---|---|
| `:sequential` | 468.6ms | 1.00× (baseline) |
| `:threads` | 467.7ms | 1.00× |
| `:processes` | 494.8ms | 0.95× |

**CPU-bound (fib(22) in pure Ruby)**

| Strategy | Time | Speedup vs `:sequential` |
|---|---|---|
| `:sequential` | 22.4ms | 1.00× (baseline) |
| `:threads` | 17.6ms | 1.28× |
| `:processes` | 33.5ms | 0.67× |


### N = 64 steps

**IO-bound (sleep 20ms)**

| Strategy | Time | Speedup vs `:sequential` |
|---|---|---|
| `:sequential` | 1.91s | 1.00× (baseline) |
| `:threads` | 2.11s | 0.91× |
| `:processes` | 2.25s | 0.85× |

**CPU-bound (fib(22) in pure Ruby)**

| Strategy | Time | Speedup vs `:sequential` |
|---|---|---|
| `:sequential` | 68.5ms | 1.00× (baseline) |
| `:threads` | 69.7ms | 0.98× |
| `:processes` | 130.9ms | 0.52× |


## Shape: `mixed`

ceil(N/4) layers of width 4 (realistic middle ground).

### N = 16 steps

**IO-bound (sleep 20ms)**

| Strategy | Time | Speedup vs `:sequential` |
|---|---|---|
| `:sequential` | 460.6ms | 1.00× (baseline) |
| `:threads` | 122.2ms | 3.77× |
| `:processes` | 123.7ms | 3.72× |

**CPU-bound (fib(22) in pure Ruby)**

| Strategy | Time | Speedup vs `:sequential` |
|---|---|---|
| `:sequential` | 22.7ms | 1.00× (baseline) |
| `:threads` | 17.7ms | 1.28× |
| `:processes` | 15.3ms | 1.48× |


### N = 64 steps

**IO-bound (sleep 20ms)**

| Strategy | Time | Speedup vs `:sequential` |
|---|---|---|
| `:sequential` | 1.89s | 1.00× (baseline) |
| `:threads` | 487.9ms | 3.88× |
| `:processes` | 501.5ms | 3.77× |

**CPU-bound (fib(22) in pure Ruby)**

| Strategy | Time | Speedup vs `:sequential` |
|---|---|---|
| `:sequential` | 67.7ms | 1.00× (baseline) |
| `:threads` | 69.5ms | 0.97× |
| `:processes` | 59.1ms | 1.15× |


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
