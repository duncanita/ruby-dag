# frozen_string_literal: true

module DAG
  module Workflow
    module Steps
      class Exec
        DEFAULT_TIMEOUT = 30
        # Shared with `Parallel::Processes`, which references it as
        # `Steps::Exec::KILL_GRACE_SECONDS` — single source of truth.
        KILL_GRACE_SECONDS = 0.1
        READ_CHUNK = 16_384

        def call(step, _input)
          command = step.config[:command]
          unless command
            return Failure.new(error: {
              code: :exec_no_command,
              message: "exec step #{step.name} has no :command config"
            })
          end

          self.class.run_command(command, timeout: step.config.fetch(:timeout, DEFAULT_TIMEOUT))
        end

        # Spawns `command`, drains stdout/stderr, returns a Result.
        #
        # `command` may be a String (passed to /bin/sh -c when it contains shell
        # metacharacters, otherwise execve'd directly) or an Array (passed as
        # argv directly to execve, no shell involved).
        #
        # SECURITY: Use the Array form for any command containing values that
        # did not come from a hard-coded literal in your source. The String form
        # will execute arbitrary shell — even values that look "safe" can
        # contain backticks, semicolons, or $(...). Do not try to escape input
        # yourself; use the Array form.
        #
        # Used by Exec#call and by RubyScript.
        def self.run_command(command, timeout:)
          pipes = []
          rd_out, wr_out = IO.pipe
          pipes.push(rd_out, wr_out)
          rd_err, wr_err = IO.pipe
          pipes.push(rd_err, wr_err)
          pid = spawn_command(command, wr_out, wr_err)
          wr_out.close
          wr_err.close

          stdout, stderr = drain_pipes(rd_out, rd_err, timeout)

          if stdout.nil?
            kill_process(pid)
            pid = nil
            return Failure.new(error: {
              code: :exec_timeout,
              message: "exec command exceeded #{timeout}s timeout",
              command: command,
              timeout_seconds: timeout
            })
          end

          # A host SIGCHLD handler (Puma, Sidekiq, etc.) can reap our child
          # before we waitpid2 it. The exec body completed and we already
          # drained stdout/stderr — surface a structured failure rather than
          # letting ECHILD escape as :step_raised.
          status =
            begin
              _, st = Process.waitpid2(pid)
              st
            rescue Errno::ECHILD
              pid = nil
              return Failure.new(error: {
                code: :exec_status_unavailable,
                message: "exec child reaped externally; exit status unavailable",
                command: command,
                stdout: stdout.strip,
                stderr: stderr.strip
              })
            end
          pid = nil
          build_result(command, stdout, stderr, status)
        ensure
          pipes.each { |io| io.close unless io.closed? }
          # :nocov: cleanup safety net for the exotic case where an exception
          # escapes between spawn and the explicit `pid = nil`. Required by
          # the process-tree-kill contract; not exercised in normal tests.
          kill_process(pid) if pid
          # :nocov:
        end

        class << self
          private

          def spawn_command(command, wr_out, wr_err)
            if command.is_a?(Array)
              Process.spawn(*command, out: wr_out, err: wr_err, pgroup: true)
            else
              Process.spawn(command, out: wr_out, err: wr_err, pgroup: true)
            end
          end

          # Note on EINTR: `read_nonblock(exception: false)` suppresses
          # `IO::WaitReadable` and `EOFError` but NOT `Errno::EINTR`, which
          # fires when a signal (typically SIGCHLD from a sibling child)
          # lands mid-syscall. Under the Threads strategy with concurrent
          # exec steps, each thread has its own spawn/drain/waitpid cycle and
          # a SIGCHLD from any child can land on any thread. Unguarded
          # `read_nonblock` crashes the thread; the strategy catches it as
          # `:step_raised` but the step was otherwise healthy. The rescue
          # retries: an interrupted read read nothing, pipe state unchanged.
          def drain_pipes(rd_out, rd_err, timeout)
            deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
            stdout_buf = +""
            stderr_buf = +""
            readers = [rd_out, rd_err]

            until readers.empty?
              remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
              return nil if remaining <= 0

              ready = IO.select(readers, nil, nil, remaining)
              next unless ready

              ready[0].each do |io|
                chunk =
                  begin
                    io.read_nonblock(READ_CHUNK, exception: false)
                    # :nocov: EINTR from SIGCHLD during concurrent exec —
                    # signal-triggered, not deterministically testable.
                  rescue Errno::EINTR
                    next
                    # :nocov:
                  end
                case chunk
                # :nocov: race between IO.select and read_nonblock — necessary
                # for correctness but not deterministically testable.
                when :wait_readable then next
                # :nocov:
                when nil then readers.delete(io)
                else ((io == rd_out) ? stdout_buf : stderr_buf) << chunk
                end
              end
            end

            [stdout_buf, stderr_buf]
          end

          def kill_process(pid)
            signal_tree("TERM", pid)
            return if poll_until_dead(pid, KILL_GRACE_SECONDS)

            signal_tree("KILL", pid)
            # KILL is uncatchable. If the child is in uninterruptible kernel
            # sleep we block here until it dies — nothing else to do from
            # userspace.
            Process.waitpid(pid)
          rescue Errno::ESRCH, Errno::ECHILD
          end

          # Polls `Process.waitpid(pid, WNOHANG)` until the child is reaped or
          # `timeout` seconds have elapsed. Returns true if reaped, false on
          # timeout.
          def poll_until_dead(pid, timeout)
            deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
            loop do
              return true if Process.waitpid(pid, Process::WNOHANG)
              return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
              sleep 0.01
            end
          end

          # Signal the process group (catches grandchildren spawned by the
          # command). The child becomes its own group leader via `pgroup: true`
          # on spawn, so `-pid` is the group ID.
          def signal_tree(sig, pid)
            Process.kill(sig, -pid)
          end

          def build_result(command, stdout, stderr, status)
            if status.success?
              Success.new(value: stdout.strip)
            else
              Failure.new(error: {
                code: :exec_failed,
                message: "exec command exited with status #{status.exitstatus}",
                exit_status: status.exitstatus,
                command: command,
                stdout: stdout.strip,
                stderr: stderr.strip
              })
            end
          end
        end
      end
    end
  end
end
