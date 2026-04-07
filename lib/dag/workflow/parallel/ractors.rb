# frozen_string_literal: true

module DAG
  module Workflow
    module Parallel
      # Ractors strategy. Runs each task in its own Ractor; results return via
      # a `Ractor::Port`. The Runner asks `supports?(steps)` per layer; if any
      # step in the layer can't be made Ractor-shareable, the Runner falls back
      # to Sequential for that layer.
      #
      # All Ractor concerns live here. `Step` itself knows nothing about
      # Ractors — this strategy lazily calls `Ractor.make_shareable(step)` the
      # first time it sees a step, caches the result by step identity, and
      # warns once per (name, type) when a step turns out not to be shareable.
      #
      # ============================================================
      # EXPERIMENTAL STRATEGY
      # ============================================================
      #
      # `Parallel::Ractors.experimental?` returns `true`. The first time a
      # Ractors strategy is instantiated in a process, a one-line warning is
      # printed to stderr summarising the limitations below and pointing at
      # `:threads` / `:processes` as stable alternatives. Subsequent
      # instantiations are silent.
      #
      # KNOWN LIMITATION ON RUBY 4.0
      # ----------------------------
      #
      # The Ractor runtime in Ruby 4.0 has its own per-Ractor deadlock detector
      # that cannot see threads in the parent process or in other Ractors. If a
      # Ractor's body blocks inside `Process.spawn` (or any syscall that the
      # detector treats as "the only thread is sleeping"), the detector trips
      # with a fatal "No live threads left. Deadlock?" error. This affects ALL
      # of the built-in step types that shell out:
      #
      #   - :exec
      #   - :ruby_script
      #
      # In practice, the Ractors strategy only runs reliably for step types
      # whose bodies are pure Ruby and never call `Process.spawn`/`fork`/
      # `IO.popen`. For everything else, **use `parallel: :threads` or
      # `parallel: :processes` instead.**
      #
      # This strategy also spawns ALL tasks at once — it does NOT honor
      # `max_parallelism` as a hard cap. An earlier windowed implementation
      # deadlocked even worse than the spawn-all version, so we fall back to
      # the same pattern the original code used. Layers larger than
      # `max_parallelism` get a one-time warning.
      #
      # If you need a hard concurrency cap, use Threads or Processes.
      class Ractors < Strategy
        def self.experimental? = true

        # Class-level dedup so repeated Runner instances don't re-warn for the
        # same step. Mutex protects against concurrent Runners.
        @warned_unshareable = Set.new
        @warned_overrun = false
        @warned_experimental = false
        @warn_mutex = Mutex.new
        class << self
          attr_reader :warned_unshareable, :warn_mutex
          attr_accessor :warned_overrun, :warned_experimental
        end

        def initialize(max_parallelism:)
          super
          warn_experimental_once
          # Cache: Step => true/false. Keyed on the Step itself (a frozen Data
          # value with field-based hash/eql?), not its object_id, so two
          # equal Steps share a slot and there is no GC-reuse footgun.
          @safe_cache = {}
        end

        def supports?(steps)
          steps.all? { |s| safe?(s) }
        end

        def execute(tasks)
          warn_if_over_capacity(tasks.size)

          results_port = Ractor::Port.new
          ractors = tasks.map { |task| spawn_ractor(task, results_port) }

          begin
            tasks.size.times do
              name, result_hash, started_at, finished_at, duration_ms = results_port.receive
              result = deserialize_result(result_hash)
              yield name, result, started_at, finished_at, duration_ms
            end
          ensure
            # Reap every Ractor even if the yield raised — otherwise the
            # strategy leaks live Ractors past its own lifetime.
            ractors.each do |r|
              r.join
            rescue
              # Already-failed Ractors re-raise on join; swallow so the
              # original exception (if any) propagates.
            end
          end
        end

        private

        # Lazy preflight: try to make the step shareable. On success the step
        # really is shareable now. On failure (or if the step is type :ruby
        # whose Proc callable is never shareable) we cache `false` and the
        # Runner will fall back to Sequential for any layer containing it.
        def safe?(step)
          @safe_cache.fetch(step) do
            @safe_cache[step] = (step.type != :ruby) && try_make_shareable(step)
          end
        end

        def try_make_shareable(step)
          Ractor.make_shareable(step)
          true
        rescue Ractor::Error, ArgumentError => e
          warn_unshareable_once(step, e)
          false
        end

        def warn_unshareable_once(step, error)
          key = [step.name, step.type]
          self.class.warn_mutex.synchronize do
            return if self.class.warned_unshareable.include?(key)
            self.class.warned_unshareable << key
          end
          warn "[DAG::Workflow::Parallel::Ractors] step #{step.name} (#{step.type}) " \
               "is not Ractor-shareable: #{error.message}. " \
               "Falling back to Sequential for any layer containing it."
        end

        def warn_experimental_once
          self.class.warn_mutex.synchronize do
            return if self.class.warned_experimental
            self.class.warned_experimental = true
          end
          warn "[DAG::Workflow::Parallel::Ractors] EXPERIMENTAL strategy: " \
               "Ruby 4.0's per-Ractor deadlock detector trips on steps that " \
               "call Process.spawn (so :exec / :ruby_script will hang), and " \
               "this strategy does not honor max_parallelism as a hard cap. " \
               "Use parallel: :threads or :processes for production workloads."
        end

        def warn_if_over_capacity(layer_size)
          return if layer_size <= @max_parallelism
          self.class.warn_mutex.synchronize do
            return if self.class.warned_overrun
            self.class.warned_overrun = true
          end
          warn "[DAG::Workflow::Parallel::Ractors] layer of #{layer_size} steps " \
               "exceeds max_parallelism=#{@max_parallelism}; the Ractors strategy " \
               "spawns all steps in a layer at once. Use parallel: :threads if you " \
               "need a hard concurrency cap."
        end

        def spawn_ractor(task, results_port)
          Ractor.new(task.name, task.step, task.input, results_port, task.executor_class) do |n, s, inp, out, klass|
            started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            result =
              begin
                klass.new.call(s, inp)
              rescue => e
                Failure.new(error: "Ractors strategy: step #{n} raised #{e.class}: #{e.message}")
              end
            finished_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            duration_ms = ((finished_at - started_at) * 1000).round(2)

            # Make the payload explicitly shareable. If the step returned a
            # value containing non-shareable objects (mutable IO, sockets, etc.)
            # surface that as a clean Failure instead of letting it crash the
            # port send and hang the parent.
            result_hash =
              begin
                Ractor.make_shareable(result.to_h)
              rescue => e
                {status: :failure, error: "step #{n} returned non-shareable value: #{e.class}: #{e.message}"}
              end

            out.send([n, result_hash, started_at, finished_at, duration_ms])
          end
        end

        def deserialize_result(hash)
          if hash[:status] == :success
            Success.new(value: hash[:value])
          else
            Failure.new(error: hash[:error])
          end
        end
      end
    end
  end
end
