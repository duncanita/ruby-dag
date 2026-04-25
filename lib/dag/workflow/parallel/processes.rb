# frozen_string_literal: true

module DAG
  module Workflow
    module Parallel
      # Process-pool strategy. Forks a child per task, runs the step in the
      # child, ships the result back through a pipe via Marshal, and reaps.
      # Windowed at `max_parallelism` so at most that many children are alive
      # at once.
      #
      # Why use this over Threads?
      #   - Memory isolation: a step that crashes the interpreter (segfault,
      #     out of memory) only kills its own child.
      #   - True parallelism for CPU-bound pure-Ruby work (bypasses the GVL).
      #
      # Constraints:
      #   - Step results must be Marshal-able. Procs, lambdas, IO objects, and
      #     anonymous classes are not. Steps that return such values surface
      #     as a clean Failure with a "non-marshalable" message.
      #   - fork() is not available on Windows. This strategy raises if
      #     `Process.respond_to?(:fork)` is false.
      #
      # Pipe drain: the parent reads each child's pipe **incrementally** with
      # `read_nonblock` inside an `IO.select` loop, so a payload larger than
      # one pipe buffer (~64 KB on Linux/macOS) does not deadlock the child.
      # The child writes the whole payload then closes its write end; the
      # parent only treats the child as done when the read returns EOF.
      class Processes < Strategy
        STRATEGY_SYM = :processes
        READ_CHUNK = 16_384
        KILL_GRACE_SECONDS = Steps::Exec::KILL_GRACE_SECONDS

        # The unit of data the child ships back over the pipe. Replaces the
        # bare positional tuple so each field is named at the call sites that
        # decode and consume it (and so future fields can be added without
        # invisibly shifting positional indexes downstream).
        ChildPayload = Data.define(:name, :result, :started_at, :finished_at, :duration_ms, :attempt_log)

        def execute(tasks)
          in_flight = {}    # pid => task
          pipes = {}        # IO  => {pid:, buffer:}
          pending = tasks.dup
          completed = 0

          while completed < tasks.size
            while in_flight.size < @max_parallelism && !pending.empty?
              task = pending.shift
              rd, wr = IO.pipe
              # :nocov: forked-child code is opaque to the parent's coverage
              # tracker (the child exits via `exit!` which skips SimpleCov's
              # flush). Tested via integration through Processes#execute.
              pid = Process.fork do
                Process.setpgrp
                rd.close
                run_in_child(task, wr)
              end
              # :nocov:
              wr.close
              in_flight[pid] = task
              pipes[rd] = {pid: pid, buffer: +""}
            end

            ready, = IO.select(pipes.keys)
            ready.each do |rd|
              info = pipes[rd]
              # :nocov: partial-data race — drain_into may return false if
              # the child wrote some data but EOF hasn't propagated yet.
              # Necessary for correctness; not deterministically testable.
              next unless drain_into(rd, info[:buffer])
              # :nocov:

              # EOF reached: child is done writing.
              pid = info[:pid]
              task = in_flight.delete(pid)
              pipes.delete(rd)
              rd.close
              status = blocking_waitpid(pid)
              payload = decode_payload(task, info[:buffer], status)
              task.attempt_log.concat(payload.attempt_log) unless payload.attempt_log.empty?
              yield payload.name, payload.result, payload.started_at, payload.finished_at, payload.duration_ms
              completed += 1
            end
          end
        ensure
          # Anything still in `pipes` at ensure time is undrained — therefore
          # still open. The normal drain path removes pipes via `pipes.delete`
          # before closing them, so a closed pipe in this hash is impossible.
          pipes.each_key(&:close)
          drain_orphans(in_flight)
        end

        private

        # Drains everything currently available on `rd` into `buffer`. Returns
        # true if EOF was hit (the child closed its write end), false if the
        # pipe is just temporarily empty and we should come back via select.
        #
        # Note on EINTR: `read_nonblock(exception: false)` only suppresses
        # `IO::WaitReadable` and `EOFError`. It does NOT suppress
        # `Errno::EINTR`, which fires when a signal (typically SIGCHLD from a
        # sibling child exiting) lands mid-syscall. Under high concurrency
        # this is common enough that an unguarded `read_nonblock` will crash
        # the parent within minutes — found by the soak rig at parallelism=32.
        # The right behavior is to retry: an interrupted read read nothing,
        # and the pipe state is unchanged.
        def drain_into(rd, buffer)
          loop do
            chunk =
              begin
                rd.read_nonblock(READ_CHUNK, exception: false)
              rescue Errno::EINTR
                next
              end
            case chunk
            # :nocov: race between IO.select and read_nonblock — same as
            # exec.rb#drain_pipes. Necessary for correctness, not testable.
            when :wait_readable then return false
            # :nocov:
            when nil then return true # EOF
            else buffer << chunk
            end
          end
        end

        # :nocov: child-only — runs in forked subprocess where coverage
        # tracking is lost when `exit!` skips SimpleCov's flush. Tested via
        # integration through Processes#execute.
        def run_in_child(task, wr)
          # task.attempt_log is mutated by the AttemptTraceMiddleware (and
          # sub_workflow passthrough) inside run_task. After fork() that
          # array lives only in the child, so we ship its post-run state
          # alongside the timing fields — the parent concats it back onto
          # the original Task before recording the trace.
          name, result, started_at, finished_at, duration_ms = run_task(task)
          payload = ChildPayload.new(name: name, result: result,
            started_at: started_at, finished_at: finished_at,
            duration_ms: duration_ms, attempt_log: task.attempt_log)
          wr.write(marshal_payload(payload))
          wr.close
          exit!(0)
        rescue => e
          # Last-ditch: try to surface the crash to the parent. If even this
          # fails, the parent will see an empty pipe and report a generic
          # crash message.
          begin
            crash = Result.exception_failure(:child_crashed, e,
              message: "child for #{task.name} crashed: #{e.message}",
              strategy: STRATEGY_SYM)
            wr.write(Marshal.dump(ChildPayload.new(name: task.name, result: crash,
              started_at: 0.0, finished_at: 0.0, duration_ms: 0.0,
              attempt_log: task.attempt_log)))
            wr.close
          rescue
            # ignore — parent will handle empty payload
          end
          exit!(1)
        end

        # On a non-marshalable step return, the fallback Failure carries the
        # original timing — the step really did run for that long, the only
        # thing that failed was shipping the value back to the parent. The
        # AttemptTraceMiddleware has by then already pushed an
        # AttemptTraceEntry with status: :success (true to the step's own
        # behavior, but out of sync with the Failure we now ship), so demote
        # that final entry to :failure to keep the trace status consistent
        # with the result the parent yields.
        def marshal_payload(payload)
          Marshal.dump(payload)
        rescue TypeError => e
          fallback = Failure.new(error: {
            code: :non_marshalable_result,
            message: "step #{payload.name} returned a non-marshalable value: #{e.message}",
            strategy: STRATEGY_SYM
          })
          Marshal.dump(payload.with(
            result: fallback,
            attempt_log: demote_final_attempt_to_failure(payload.attempt_log)
          ))
        end
        # :nocov:

        # :nocov: OS-level edge cases (signal kill, ECHILD race) are not
        # deterministically testable; the common case (clean exit) is tested.
        def child_status_detail(name, status)
          if status.nil?
            "no status available"
          elsif status.signaled?
            "killed by signal #{status.termsig}"
          else
            "exited #{status.exitstatus}"
          end
        end
        # :nocov:

        def decode_payload(task, payload, child_status = nil)
          if payload.empty?
            now = @clock.monotonic_now
            detail = child_status_detail(task.name, child_status)
            result = Failure.new(error: {
              code: :empty_child_payload,
              message: "child for #{task.name} exited without writing a payload (#{detail})",
              strategy: STRATEGY_SYM
            })
            return ChildPayload.new(name: task.name, result: result,
              started_at: now, finished_at: now, duration_ms: 0.0, attempt_log: [])
          end

          Marshal.load(payload)
        rescue => e
          now = @clock.monotonic_now
          result = Result.exception_failure(:decode_failed, e,
            message: "failed to decode payload from #{task.name}: #{e.message}",
            strategy: STRATEGY_SYM)
          ChildPayload.new(name: task.name, result: result,
            started_at: now, finished_at: now, duration_ms: 0.0, attempt_log: [])
        end

        # Rewrites the final AttemptTraceEntry in the log to status: :failure.
        # Called only when the marshal fallback substitutes a Failure for a
        # non-marshalable step return — preserves earlier attempts and any
        # sub_workflow passthrough entries unchanged.
        def demote_final_attempt_to_failure(attempt_log)
          last_idx = attempt_log.rindex { |entry| entry.is_a?(AttemptTraceEntry) }
          return attempt_log if last_idx.nil?
          return attempt_log if attempt_log[last_idx].status == :failure

          attempt_log.each_with_index.map do |entry, i|
            (i == last_idx) ? entry.with(status: :failure) : entry
          end
        end

        # Concurrent TERM -> grace -> KILL -> grace ladder. Signals go
        # out to all pids at once, then we poll the whole set in a single
        # WNOHANG loop. Total wall-clock for N orphans is bounded by
        # 2 * KILL_GRACE_SECONDS regardless of N — per-child sequential
        # cleanup would be N * 200ms, which is a real pessimization at
        # high max_parallelism.
        def drain_orphans(in_flight)
          alive = in_flight.keys
          alive = signal_then_reap(alive, "TERM", KILL_GRACE_SECONDS)
          alive = signal_then_reap(alive, "KILL", KILL_GRACE_SECONDS)
          # Last-ditch blocking wait for anything still in uninterruptible
          # sleep. Nothing more we can do from userspace.
          alive.each { |pid| blocking_waitpid(pid) }
        end

        def signal_then_reap(pids, sig, grace)
          return pids if pids.empty?
          pids.each do |pid|
            Process.kill(sig, -pid)
          rescue Errno::ESRCH
            # group already gone
          end
          reap_batch(pids, grace)
        end

        # Returns the list of pids still alive after the grace period.
        def reap_batch(pids, grace)
          remaining = pids.dup
          deadline = @clock.monotonic_now + grace
          until remaining.empty?
            remaining.reject! { |pid| waitpid_nohang(pid) }
            break if @clock.monotonic_now >= deadline
            sleep 0.01
          end
          remaining
        end

        def waitpid_nohang(pid)
          !Process.waitpid(pid, Process::WNOHANG).nil?
        rescue Errno::ECHILD
          true
        end

        def blocking_waitpid(pid)
          _, status = Process.waitpid2(pid)
          status
        rescue Errno::ECHILD
          # :nocov: requires child already reaped by concurrent path
          nil
          # :nocov:
        end
      end
    end
  end
end
