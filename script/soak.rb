#!/usr/bin/env ruby
# frozen_string_literal: true

# Soak harness for DAG::Workflow::Parallel strategies.
#
# Stresses each strategy under sustained load — megabyte payloads,
# max_parallelism=32, thousands of rounds — to validate the cleanup paths
# that unit tests only touch once or twice each:
#
#   :processes  — drain_orphans (processes.rb:156) TERM->KILL ladder, plus
#                 the read_nonblock pipe drain (processes.rb:84). Round modes
#                 :clean / :one_fault / :stuck_kill exercise the happy path,
#                 the ensure-path with mixed completion, and the ensure-path
#                 with real sleeping orphans the ladder must signal.
#
#   :threads    — spawn_worker ensure block (threads.rb:52) that pushes a
#                 synthetic :worker_died Failure if a worker dies below
#                 StandardError. Round modes :clean / :one_fault / :worker_death
#                 cover the happy path, in-flight workers being abandoned by
#                 an early-exiting execute, and the worker-death safety net.
#
#   :sequential — baseline. :clean only. Catches any leak introduced by the
#                 shared scaffolding rather than the strategy itself.
#
# Usage:
#   ruby script/soak.rb --strategy processes
#   ruby script/soak.rb --all --short                # ~3-minute smoke run
#
# Exits 0 on PASS, 1 on any health-check trip or failed acceptance criteria.

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "dag"
require "optparse"
require "digest"
require "timeout"

module DAGSoak
  Boom = Class.new(StandardError)

  STRATEGIES = {
    sequential: DAG::Workflow::Parallel::Sequential,
    threads: DAG::Workflow::Parallel::Threads,
    processes: DAG::Workflow::Parallel::Processes
  }.freeze

  MODES_FOR = {
    sequential: %i[clean].freeze,
    threads: %i[clean one_fault worker_death].freeze,
    processes: %i[clean one_fault stuck_kill].freeze
  }.freeze

  WORKER_DEATH_TYPE = :soak_worker_death

  module_function

  # ---------- payload + tasks ----------

  def make_payload(bytes)
    payload = Random.bytes(bytes)
    [payload, Digest::SHA256.hexdigest(payload)]
  end

  def fast_big_task(name, payload_callable)
    step = DAG::Workflow::Step.new(name: name, type: :ruby, callable: payload_callable)
    DAG::Workflow::Parallel::Task.new(
      name: name,
      step: step,
      input: {},
      executor_class: DAG::Workflow::Steps::Ruby,
      input_keys: []
    )
  end

  def slow_sleeper_task(name, seconds)
    callable = ->(_input) {
      sleep(seconds)
      DAG::Success.new(value: :slept)
    }
    step = DAG::Workflow::Step.new(name: name, type: :ruby, callable: callable)
    DAG::Workflow::Parallel::Task.new(
      name: name,
      step: step,
      input: {},
      executor_class: DAG::Workflow::Steps::Ruby,
      input_keys: []
    )
  end

  def worker_death_task(name)
    step = DAG::Workflow::Step.new(name: name, type: WORKER_DEATH_TYPE)
    DAG::Workflow::Parallel::Task.new(
      name: name,
      step: step,
      input: {},
      executor_class: DAG::Workflow::Steps.class_for(WORKER_DEATH_TYPE),
      input_keys: []
    )
  end

  def register_worker_death_step
    return if DAG::Workflow::Steps.registered?(WORKER_DEATH_TYPE)
    klass = Class.new do
      def call(_step, _input)
        raise NoMemoryError, "soak: simulated worker death"
      end
    end
    DAG::Workflow::Steps.register(WORKER_DEATH_TYPE, klass, yaml_safe: false)
  end

  # ---------- stats ----------

  class Stats
    attr_accessor :strategy, :rounds, :rounds_by_mode, :tasks_completed,
      :tasks_drained, :bytes_verified, :checksum_failures,
      :cleanup_ms_samples, :zombies_seen,
      :rss_initial, :rss_peak, :fds_initial, :fds_peak,
      :threads_initial, :threads_peak,
      :wall_gaps_seen, :wall_gap_total_seconds

    def initialize(strategy)
      @strategy = strategy
      @rounds = 0
      @rounds_by_mode = Hash.new(0)
      @tasks_completed = 0
      @tasks_drained = 0
      @bytes_verified = 0
      @checksum_failures = 0
      @cleanup_ms_samples = []
      @zombies_seen = 0
      @wall_gaps_seen = 0
      @wall_gap_total_seconds = 0.0
    end

    def cleanup_ms_max = cleanup_ms_samples.max || 0.0

    def cleanup_ms_p99
      return 0.0 if cleanup_ms_samples.empty?
      sorted = cleanup_ms_samples.sort
      sorted[(sorted.length * 0.99).floor.clamp(0, sorted.length - 1)]
    end
  end

  # ---------- environment probes ----------

  def current_rss_mb
    kb = `ps -o rss= -p #{Process.pid}`.to_i
    (kb / 1024.0).round(1)
  end

  def current_fds
    Dir.children("/dev/fd").size
  rescue Errno::ENOENT
    begin
      Dir.children("/proc/self/fd").size
    rescue Errno::ENOENT
      -1
    end
  end

  def current_threads = Thread.list.size

  def reap_zombies
    count = 0
    loop do
      pid = Process.waitpid(-1, Process::WNOHANG)
      break if pid.nil?
      count += 1
    end
    count
  rescue Errno::ECHILD
    count
  end

  # ---------- per-round drivers ----------

  def verify(name, result, expected_size, expected_sha, stats)
    unless result.is_a?(DAG::Success)
      stats.checksum_failures += 1
      warn "!! #{name} returned non-Success: #{result.inspect}"
      return false
    end
    value = result.value
    if value.bytesize != expected_size
      stats.checksum_failures += 1
      warn "!! #{name} size mismatch: got #{value.bytesize} want #{expected_size}"
      return false
    end
    if Digest::SHA256.hexdigest(value) != expected_sha
      stats.checksum_failures += 1
      warn "!! #{name} sha mismatch (size ok)"
      return false
    end
    stats.bytes_verified += value.bytesize
    true
  end

  def run_round(strategy, mode, options, payload_info, stats)
    payload, sha = payload_info
    parallelism = options[:parallelism]
    payload_callable = ->(_input) { DAG::Success.new(value: payload) }

    case mode
    when :clean
      tasks = Array.new(parallelism) { |i| fast_big_task(:"f#{i}", payload_callable) }
      strategy.execute(tasks) do |name, result, *|
        verify(name, result, payload.bytesize, sha, stats)
        stats.tasks_completed += 1
      end

    when :one_fault
      tasks = Array.new(parallelism) { |i| fast_big_task(:"f#{i}", payload_callable) }
      raise_after = [parallelism / 4, 1].max
      completed_in_round = 0
      raise_at = nil
      begin
        strategy.execute(tasks) do |name, result, *|
          verify(name, result, payload.bytesize, sha, stats)
          stats.tasks_completed += 1
          completed_in_round += 1
          if completed_in_round >= raise_after
            raise_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            raise Boom
          end
        end
      rescue Boom
        cleanup_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - raise_at) * 1000
        stats.cleanup_ms_samples << cleanup_ms
        stats.tasks_drained += (parallelism - completed_in_round)
      end

    when :stuck_kill
      # 1 fast trigger + (N-1) real sleepers. The orphan ladder must
      # actually TERM->KILL the sleepers, not just reap fast exiters.
      tasks = [fast_big_task(:f0, payload_callable)] +
        Array.new(parallelism - 1) { |i| slow_sleeper_task(:"s#{i}", 30) }
      raise_at = nil
      begin
        strategy.execute(tasks) do |name, _result, *|
          if name == :f0
            stats.tasks_completed += 1
            raise_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            raise Boom
          end
        end
      rescue Boom
        cleanup_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - raise_at) * 1000
        stats.cleanup_ms_samples << cleanup_ms
        stats.tasks_drained += (parallelism - 1)
      end

    when :worker_death
      # (N-1) fast tasks + 1 worker that raises NoMemoryError. The worker
      # ensure block must push a synthetic :worker_died Failure so the
      # parent's queue.pop doesn't deadlock.
      tasks = Array.new(parallelism - 1) { |i| fast_big_task(:"f#{i}", payload_callable) } +
        [worker_death_task(:dies)]
      saw_death = false
      strategy.execute(tasks) do |name, result, *|
        if name == :dies
          if result.failure? && result.error[:code] == :worker_died
            saw_death = true
          else
            stats.checksum_failures += 1
            warn "!! :dies expected :worker_died, got #{result.inspect}"
          end
        else
          verify(name, result, payload.bytesize, sha, stats)
        end
        stats.tasks_completed += 1
      end
      unless saw_death
        stats.checksum_failures += 1
        warn "!! :worker_death round did not surface a :worker_died failure"
      end
    end

    stats.rounds += 1
    stats.rounds_by_mode[mode] += 1
  end

  # ---------- soak loop ----------

  # 1024 MB is generous on purpose. Forking N children with M-MB payloads
  # naturally inflates the parent's RSS by N*M (Marshal buffers + heap pages
  # macOS won't release until process exit). A leak on top of that working
  # set has to clear the floor before we trip. Subtler leaks are below the
  # noise floor of `ps -o rss` and not worth catching with this tool.
  RSS_GROWTH_FLOOR_MB = 1024

  def health_ok?(stats)
    return false if stats.checksum_failures > 0
    return false if stats.zombies_seen > 0
    return false if current_fds > stats.fds_initial + 16
    return false if current_threads > stats.threads_initial + 4
    rss = current_rss_mb
    return false if rss > 2 * stats.rss_initial && rss > stats.rss_initial + RSS_GROWTH_FLOOR_MB
    true
  end

  def soak_one(strategy_sym, options, payload_info)
    klass = STRATEGIES.fetch(strategy_sym)
    strategy = klass.new(max_parallelism: options[:parallelism])

    stats = Stats.new(strategy_sym)
    stats.rss_initial = current_rss_mb
    stats.rss_peak = stats.rss_initial
    stats.fds_initial = current_fds
    stats.fds_peak = stats.fds_initial
    stats.threads_initial = current_threads
    stats.threads_peak = stats.threads_initial

    t_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    deadline = t_start + options[:duration]
    next_status = t_start + options[:status_interval]
    last_tick = t_start
    # If the gap between two loop iterations exceeds this, the process was
    # almost certainly frozen (laptop sleep, SIGSTOP, severe CPU starvation)
    # and the strategy wasn't actually running during that window — not a
    # health failure, but the operator needs to know their "60 minute soak"
    # was really 45 minutes of run plus 15 minutes of nap.
    gap_threshold = options[:status_interval] * 3

    mode_cycle = MODES_FOR.fetch(strategy_sym).cycle

    warn "[#{strategy_sym}] soak start — duration=#{options[:duration]}s parallelism=#{options[:parallelism]} payload=#{format_bytes(options[:payload_bytes])}"
    warn "[#{strategy_sym}] initial: rss=#{stats.rss_initial}MB fds=#{stats.fds_initial} threads=#{stats.threads_initial}"

    begin
      loop do
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        gap = now - last_tick
        if gap > gap_threshold
          stats.wall_gaps_seen += 1
          stats.wall_gap_total_seconds += gap
          warn format(
            "!! [%s] wall-clock gap of %.1fs at t+%s — process was frozen (laptop sleep / CPU stall); strategy wasn't running during this window",
            strategy_sym, gap, format_duration((now - t_start).to_i)
          )
        end
        break if now >= deadline

        mode = mode_cycle.next
        begin
          Timeout.timeout(options[:round_timeout]) do
            run_round(strategy, mode, options, payload_info, stats)
          end
        rescue Timeout::Error
          warn "!! [#{strategy_sym}] round #{stats.rounds + 1} (#{mode}) timed out after #{options[:round_timeout]}s"
          stats.checksum_failures += 1
          stats.rounds += 1
          stats.rounds_by_mode[mode] += 1
        end

        stats.zombies_seen += reap_zombies if strategy_sym == :processes

        rss = current_rss_mb
        fds = current_fds
        threads = current_threads
        stats.rss_peak = rss if rss > stats.rss_peak
        stats.fds_peak = fds if fds > stats.fds_peak
        stats.threads_peak = threads if threads > stats.threads_peak

        unless health_ok?(stats)
          warn "!! [#{strategy_sym}] HEALTH CHECK FAILED after round #{stats.rounds} (#{mode})"
          print_status(strategy_sym, stats, t_start)
          return [stats, false]
        end

        last_tick = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if last_tick >= next_status
          print_status(strategy_sym, stats, t_start)
          next_status += options[:status_interval]
        end
      end
    rescue Interrupt
      warn "!! [#{strategy_sym}] interrupted; printing partial stats"
      print_status(strategy_sym, stats, t_start)
      return [stats, false]
    end

    print_status(strategy_sym, stats, t_start)
    [stats, pass?(strategy_sym, stats)]
  end

  def pass?(strategy_sym, stats)
    return false if stats.checksum_failures > 0
    return false if stats.zombies_seen > 0
    return false if stats.fds_peak > stats.fds_initial + 8
    return false if stats.threads_peak > stats.threads_initial + 4
    return false if stats.rss_peak > 1.5 * stats.rss_initial && stats.rss_peak > stats.rss_initial + RSS_GROWTH_FLOOR_MB

    case strategy_sym
    when :processes
      return false unless stats.tasks_drained > 0
      return false unless stats.rounds_by_mode[:one_fault] > 0
      return false unless stats.rounds_by_mode[:stuck_kill] > 0
      return false if stats.cleanup_ms_max > 1500
    when :threads
      return false unless stats.rounds_by_mode[:worker_death] > 0
      return false if stats.cleanup_ms_max > 100
    end
    true
  end

  # ---------- formatting ----------

  def format_duration(sec)
    h, rem = sec.divmod(3600)
    m, s = rem.divmod(60)
    format("%02d:%02d:%02d", h, m, s)
  end

  def format_bytes(n)
    return "#{n}B" if n < 1024
    units = %w[KB MB GB TB]
    f = n.to_f
    unit = nil
    units.each do |u|
      f /= 1024.0
      unit = u
      break if f < 1024
    end
    format("%.1f%s", f, unit)
  end

  def print_status(strategy_sym, stats, t_start)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t_start
    rss = current_rss_mb
    fds = current_fds
    threads = current_threads

    by = stats.rounds_by_mode
    mode_summary = MODES_FOR.fetch(strategy_sym).map { |m| "#{m}=#{by[m]}" }.join(" ")

    warn format(
      "[t+%s] %s rounds=%d (%s) tasks=%d drained=%d bytes=%s cksum=%d zombies=%d cleanup_ms max=%.0f p99=%.0f rss=%.1fMB(%+.1f) fds=%d(%+d) threads=%d(%+d)",
      format_duration(elapsed.to_i), strategy_sym, stats.rounds, mode_summary,
      stats.tasks_completed, stats.tasks_drained, format_bytes(stats.bytes_verified),
      stats.checksum_failures, stats.zombies_seen,
      stats.cleanup_ms_max, stats.cleanup_ms_p99,
      rss, rss - stats.rss_initial,
      fds, fds - stats.fds_initial,
      threads, threads - stats.threads_initial
    )
  end

  def run(options)
    register_worker_death_step
    payload_info = make_payload(options[:payload_bytes])

    targets = options[:all] ? STRATEGIES.keys : [options[:strategy]]

    results = targets.map do |sym|
      stats, pass = soak_one(sym, options, payload_info)
      [sym, pass, stats]
    end

    warn ""
    warn "==== SUMMARY ===="
    results.each do |sym, pass, stats|
      line = "  #{sym}: #{pass ? "PASS" : "FAIL"}"
      if stats.wall_gaps_seen > 0
        line += format(" (warning: %d wall-clock gap%s totalling %.1fs — actual soak time was shorter than requested)",
          stats.wall_gaps_seen, (stats.wall_gaps_seen == 1) ? "" : "s", stats.wall_gap_total_seconds)
      end
      warn line
    end
    (results.all? { |_, pass, _| pass }) ? 0 : 1
  end
end

# ---------- CLI ----------

options = {
  strategy: nil,
  all: false,
  duration: 3600,
  parallelism: 32,
  payload_bytes: 1_048_576,
  status_interval: 30,
  round_timeout: 60
}

OptionParser.new do |opts|
  opts.banner = "Usage: ruby script/soak.rb --strategy {sequential|threads|processes} [options]"
  opts.on("--strategy NAME", String, "Strategy to soak (sequential|threads|processes)") do |v|
    sym = v.to_sym
    unless DAGSoak::STRATEGIES.key?(sym)
      warn "unknown strategy: #{v} (allowed: #{DAGSoak::STRATEGIES.keys.join(", ")})"
      exit 2
    end
    options[:strategy] = sym
  end
  opts.on("--all", "Soak all three strategies back-to-back") { options[:all] = true }
  opts.on("--duration SEC", Integer, "Soak duration per strategy (default 3600)") { |v| options[:duration] = v }
  opts.on("--parallelism N", Integer, "max_parallelism (default 32)") { |v| options[:parallelism] = v }
  opts.on("--payload-bytes B", Integer, "Per-task payload size (default 1_048_576)") { |v| options[:payload_bytes] = v }
  opts.on("--status-interval SEC", Integer, "Status print cadence (default 30)") { |v| options[:status_interval] = v }
  opts.on("--round-timeout SEC", Integer, "Per-round watchdog (default 60)") { |v| options[:round_timeout] = v }
  opts.on("--short", "60s smoke run, parallelism 8") do
    options[:duration] = 60
    options[:parallelism] = 8
    options[:status_interval] = 10
  end
  opts.on_tail("-h", "--help") do
    puts opts
    exit
  end
end.parse!

if !options[:all] && options[:strategy].nil?
  warn "error: --strategy or --all required"
  exit 2
end

exit(DAGSoak.run(options))
