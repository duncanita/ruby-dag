# ruby-dag benchmarks

_Generated 2026-04-07 22:54:13 UTC_

| Field | Value |
|---|---|
| Ruby | `ruby 4.0.2 (2026-03-17 revision d3da9fec82) +PRISM [arm64-darwin25]` |
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
| `:sequential` | 486.2ms | 1.00× (baseline) |
| `:threads` | 63.8ms | 7.63× |
| `:processes` | 65.6ms | 7.41× |

**CPU-bound (fib(22) in pure Ruby)**

| Strategy | Time | Speedup vs `:sequential` |
|---|---|---|
| `:sequential` | 19.9ms | 1.00× (baseline) |
| `:threads` | 17.8ms | 1.12× |
| `:processes` | 10.1ms | 1.97× |


### N = 64 steps

**IO-bound (sleep 20ms)**

| Strategy | Time | Speedup vs `:sequential` |
|---|---|---|
| `:sequential` | 1.92s | 1.00× (baseline) |
| `:threads` | 230.3ms | 8.32× |
| `:processes` | 233.9ms | 8.19× |

**CPU-bound (fib(22) in pure Ruby)**

| Strategy | Time | Speedup vs `:sequential` |
|---|---|---|
| `:sequential` | 65.2ms | 1.00× (baseline) |
| `:threads` | 67.5ms | 0.97× |
| `:processes` | 35.9ms | 1.81× |


## Shape: `chain`

N steps in N sequential layers (no parallelism possible — measures per-step overhead).

### N = 16 steps

**IO-bound (sleep 20ms)**

| Strategy | Time | Speedup vs `:sequential` |
|---|---|---|
| `:sequential` | 486.7ms | 1.00× (baseline) |
| `:threads` | 485.0ms | 1.00× |
| `:processes` | 515.8ms | 0.94× |

**CPU-bound (fib(22) in pure Ruby)**

| Strategy | Time | Speedup vs `:sequential` |
|---|---|---|
| `:sequential` | 23.0ms | 1.00× (baseline) |
| `:threads` | 17.8ms | 1.29× |
| `:processes` | 32.2ms | 0.71× |


### N = 64 steps

**IO-bound (sleep 20ms)**

| Strategy | Time | Speedup vs `:sequential` |
|---|---|---|
| `:sequential` | 1.92s | 1.00× (baseline) |
| `:threads` | 1.95s | 0.99× |
| `:processes` | 2.02s | 0.95× |

**CPU-bound (fib(22) in pure Ruby)**

| Strategy | Time | Speedup vs `:sequential` |
|---|---|---|
| `:sequential` | 65.8ms | 1.00× (baseline) |
| `:threads` | 66.4ms | 0.99× |
| `:processes` | 129.9ms | 0.51× |


## Shape: `mixed`

ceil(N/4) layers of width 4 (realistic middle ground).

### N = 16 steps

**IO-bound (sleep 20ms)**

| Strategy | Time | Speedup vs `:sequential` |
|---|---|---|
| `:sequential` | 481.4ms | 1.00× (baseline) |
| `:threads` | 124.3ms | 3.87× |
| `:processes` | 125.3ms | 3.84× |

**CPU-bound (fib(22) in pure Ruby)**

| Strategy | Time | Speedup vs `:sequential` |
|---|---|---|
| `:sequential` | 21.6ms | 1.00× (baseline) |
| `:threads` | 16.9ms | 1.28× |
| `:processes` | 15.7ms | 1.37× |


### N = 64 steps

**IO-bound (sleep 20ms)**

| Strategy | Time | Speedup vs `:sequential` |
|---|---|---|
| `:sequential` | 1.92s | 1.00× (baseline) |
| `:threads` | 505.3ms | 3.80× |
| `:processes` | 502.0ms | 3.83× |

**CPU-bound (fib(22) in pure Ruby)**

| Strategy | Time | Speedup vs `:sequential` |
|---|---|---|
| `:sequential` | 65.6ms | 1.00× (baseline) |
| `:threads` | 66.3ms | 0.99× |
| `:processes` | 56.7ms | 1.16× |


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
