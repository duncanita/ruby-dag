# ruby-dag benchmarks

_Generated 2026-04-07 23:04:14 UTC_

| Field | Value |
|---|---|
| Ruby | `ruby 3.4.9 (2026-03-11 revision 76cca827ab) +PRISM [arm64-darwin25]` |
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
| `:sequential` | 478.4ms | 1.00× (baseline) |
| `:threads` | 61.9ms | 7.73× |
| `:processes` | 61.5ms | 7.77× |

**CPU-bound (fib(22) in pure Ruby)**

| Strategy | Time | Speedup vs `:sequential` |
|---|---|---|
| `:sequential` | 22.4ms | 1.00× (baseline) |
| `:threads` | 20.2ms | 1.11× |
| `:processes` | 10.8ms | 2.08× |


### N = 64 steps

**IO-bound (sleep 20ms)**

| Strategy | Time | Speedup vs `:sequential` |
|---|---|---|
| `:sequential` | 1.92s | 1.00× (baseline) |
| `:threads` | 227.3ms | 8.46× |
| `:processes` | 236.4ms | 8.14× |

**CPU-bound (fib(22) in pure Ruby)**

| Strategy | Time | Speedup vs `:sequential` |
|---|---|---|
| `:sequential` | 78.8ms | 1.00× (baseline) |
| `:threads` | 77.4ms | 1.02× |
| `:processes` | 40.5ms | 1.95× |


## Shape: `chain`

N steps in N sequential layers (no parallelism possible — measures per-step overhead).

### N = 16 steps

**IO-bound (sleep 20ms)**

| Strategy | Time | Speedup vs `:sequential` |
|---|---|---|
| `:sequential` | 467.9ms | 1.00× (baseline) |
| `:threads` | 481.8ms | 0.97× |
| `:processes` | 511.8ms | 0.91× |

**CPU-bound (fib(22) in pure Ruby)**

| Strategy | Time | Speedup vs `:sequential` |
|---|---|---|
| `:sequential` | 23.8ms | 1.00× (baseline) |
| `:threads` | 19.8ms | 1.20× |
| `:processes` | 34.9ms | 0.68× |


### N = 64 steps

**IO-bound (sleep 20ms)**

| Strategy | Time | Speedup vs `:sequential` |
|---|---|---|
| `:sequential` | 1.93s | 1.00× (baseline) |
| `:threads` | 1.92s | 1.01× |
| `:processes` | 2.02s | 0.96× |

**CPU-bound (fib(22) in pure Ruby)**

| Strategy | Time | Speedup vs `:sequential` |
|---|---|---|
| `:sequential` | 77.8ms | 1.00× (baseline) |
| `:threads` | 79.3ms | 0.98× |
| `:processes` | 139.5ms | 0.56× |


## Shape: `mixed`

ceil(N/4) layers of width 4 (realistic middle ground).

### N = 16 steps

**IO-bound (sleep 20ms)**

| Strategy | Time | Speedup vs `:sequential` |
|---|---|---|
| `:sequential` | 479.5ms | 1.00× (baseline) |
| `:threads` | 126.2ms | 3.80× |
| `:processes` | 125.7ms | 3.81× |

**CPU-bound (fib(22) in pure Ruby)**

| Strategy | Time | Speedup vs `:sequential` |
|---|---|---|
| `:sequential` | 23.2ms | 1.00× (baseline) |
| `:threads` | 19.7ms | 1.17× |
| `:processes` | 16.3ms | 1.42× |


### N = 64 steps

**IO-bound (sleep 20ms)**

| Strategy | Time | Speedup vs `:sequential` |
|---|---|---|
| `:sequential` | 1.96s | 1.00× (baseline) |
| `:threads` | 492.9ms | 3.97× |
| `:processes` | 502.9ms | 3.89× |

**CPU-bound (fib(22) in pure Ruby)**

| Strategy | Time | Speedup vs `:sequential` |
|---|---|---|
| `:sequential` | 78.1ms | 1.00× (baseline) |
| `:threads` | 77.4ms | 1.01× |
| `:processes` | 64.2ms | 1.22× |


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
