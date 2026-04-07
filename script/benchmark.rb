#!/usr/bin/env ruby
# frozen_string_literal: true

# ruby-dag benchmark harness. Runs synthetic workflows across the stable
# strategies and emits a markdown report suitable for release notes.
#
#   ruby script/benchmark.rb [--out PATH] [--quick]
#
# Numbers are not portable across machines — re-run on the target before
# drawing conclusions.

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "dag"
require "optparse"
require "rbconfig"

module DAGBench
  RUNS_PER_CELL = 3
  STRATEGIES = %i[sequential threads processes].freeze
  MAX_PARALLELISM = DAG::Workflow::Runner::DEFAULT_MAX_PARALLELISM
  SIZES = [16, 64].freeze
  SIZES_QUICK = [16].freeze
  SHAPES = %i[fan_out chain mixed].freeze

  WORKLOADS = {
    io: {
      label: "IO-bound (sleep 20ms)",
      step_type: :exec,
      config: ->(_i) { {command: "sleep 0.02"} }
    },
    cpu: {
      label: "CPU-bound (fib(22) in pure Ruby)",
      step_type: :ruby,
      config: ->(_i) {
        {
          callable: lambda do |_input|
            fib = ->(n) { (n < 2) ? n : fib.call(n - 1) + fib.call(n - 2) }
            DAG::Success.new(value: fib.call(22))
          end
        }
      }
    }
  }.freeze

  SHAPE_DESCRIPTIONS = {
    fan_out: "All N steps in a single topological layer (maximum parallelism opportunity).",
    chain: "N steps in N sequential layers (no parallelism possible — measures per-step overhead).",
    mixed: "ceil(N/4) layers of width 4 (realistic middle ground)."
  }.freeze

  module_function

  def build(shape, workload, n)
    graph = DAG::Graph.new
    registry = DAG::Workflow::Registry.new
    add = ->(name, i) {
      graph.add_node(name)
      registry.register(DAG::Workflow::Step.new(name: name, type: workload[:step_type], **workload[:config].call(i)))
    }

    case shape
    when :fan_out
      n.times { |i| add.call(:"n#{i}", i) }
    when :chain
      n.times do |i|
        add.call(:"n#{i}", i)
        graph.add_edge(:"n#{i - 1}", :"n#{i}") if i > 0
      end
    when :mixed
      width = 4
      depth = (n / width.to_f).ceil
      depth.times do |layer|
        width.times do |col|
          add.call(:"l#{layer}c#{col}", layer * width + col)
          graph.add_edge(:"l#{layer - 1}c#{col}", :"l#{layer}c#{col}") if layer > 0
        end
      end
    end

    DAG::Workflow::Definition.new(graph: graph, registry: registry)
  end

  def measure(definition, strategy)
    samples = RUNS_PER_CELL.times.map do
      runner = DAG::Workflow::Runner.new(definition, parallel: strategy, max_parallelism: MAX_PARALLELISM)
      t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = runner.call
      return nil unless result.success?
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000
    end
    samples.sort[RUNS_PER_CELL / 2]
  end

  def run_matrix(sizes:, progress: nil)
    SHAPES.to_h do |shape|
      [shape, sizes.to_h do |n|
        [n, WORKLOADS.to_h do |wkey, wspec|
          [wkey, STRATEGIES.to_h do |strategy|
            progress&.call("#{shape} N=#{n} #{wkey} #{strategy}")
            [strategy, measure(build(shape, wspec, n), strategy)]
          end]
        end]
      end]
    end
  end

  def format_ms(v)
    return "—" unless v
    (v >= 1000) ? format("%.2fs", v / 1000.0) : format("%.1fms", v)
  end

  def speedup(seq, other)
    return "—" if seq.nil? || other.nil? || other.zero?
    format("%.2f×", seq / other)
  end

  def render(results, sizes:)
    out = +header
    SHAPES.each do |shape|
      out << "\n## Shape: `#{shape}`\n\n#{SHAPE_DESCRIPTIONS[shape]}\n"
      sizes.each do |n|
        out << "\n### N = #{n} steps\n\n"
        WORKLOADS.each do |wkey, wspec|
          out << "**#{wspec[:label]}**\n\n#{strategy_table(results[shape][n][wkey])}\n"
        end
      end
    end
    out << methodology
  end

  def header
    <<~MD
      # ruby-dag benchmarks

      _Generated #{Time.now.utc.strftime("%Y-%m-%d %H:%M:%S UTC")}_

      | Field | Value |
      |---|---|
      | Ruby | `#{RUBY_DESCRIPTION}` |
      | Platform | `#{RbConfig::CONFIG["host_os"]} (#{RbConfig::CONFIG["host_cpu"]})` |
      | Logical cores | #{Etc.nprocessors} |
      | `max_parallelism` | #{MAX_PARALLELISM} |
      | Runs per cell | #{RUNS_PER_CELL} (median reported) |

      All cells are wall-clock medians. Lower is better.
    MD
  end

  def strategy_table(cells)
    seq = cells[:sequential]
    rows = STRATEGIES.map do |s|
      speedup_col = (s == :sequential) ? "1.00× (baseline)" : speedup(seq, cells[s])
      "| `:#{s}` | #{format_ms(cells[s])} | #{speedup_col} |"
    end
    "| Strategy | Time | Speedup vs `:sequential` |\n|---|---|---|\n#{rows.join("\n")}\n"
  end

  def methodology
    <<~MD

      ---

      ## Methodology

      * Each cell is the **median of #{RUNS_PER_CELL} runs** of the same workflow definition.
      * Wall-clock only (`Process.clock_gettime(CLOCK_MONOTONIC)`).
      * `max_parallelism` = `DAG::Workflow::Runner::DEFAULT_MAX_PARALLELISM` (`[Etc.nprocessors, 8].min`).
      * IO-bound workload: `exec` steps running `sleep 0.02`. CPU-bound: `:ruby` steps computing naive recursive `fib(22)`.
      * `:processes` pays a per-step `fork()` cost; expect it to lose at small N and win at large N.
      * `:threads` releases the GVL in `sleep` / `Process.spawn` so it scales on IO-bound; on CPU-bound it serializes through the GVL.

      Reproduce:

      ```sh
      ruby script/benchmark.rb --out benchmarks/$(date +%Y-%m-%d).md
      ```
    MD
  end
end

# ---------- CLI ----------

options = {out: nil, quick: false}
OptionParser.new do |opts|
  opts.banner = "Usage: ruby script/benchmark.rb [options]"
  opts.on("--out PATH", "Write report to PATH instead of stdout") { |v| options[:out] = v }
  opts.on("--quick", "Run a smaller matrix (~15s)") { options[:quick] = true }
  opts.on_tail("-h", "--help", "Show help") do
    puts opts
    exit
  end
end.parse!

sizes = options[:quick] ? DAGBench::SIZES_QUICK : DAGBench::SIZES

warn "ruby-dag benchmark — sizes: #{sizes.inspect}, strategies: #{DAGBench::STRATEGIES.inspect}"
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
results = DAGBench.run_matrix(sizes: sizes, progress: ->(label) { warn "  • #{label}" })
warn "Done in #{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(1)}s."

report = DAGBench.render(results, sizes: sizes)

if options[:out]
  File.write(options[:out], report)
  warn "Wrote #{options[:out]}"
else
  puts report
end
