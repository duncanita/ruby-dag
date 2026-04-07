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
          rd_out, wr_out = IO.pipe
          rd_err, wr_err = IO.pipe
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

          _, status = Process.waitpid2(pid)
          pid = nil
          build_result(command, stdout, stderr, status)
        ensure
          [rd_out, wr_out, rd_err, wr_err].each { |io| io&.close unless io&.closed? }
          kill_process(pid) if pid
        end

        class << self
          private

          def spawn_command(command, wr_out, wr_err)
            if command.is_a?(Array)
              Process.spawn(*command, out: wr_out, err: wr_err)
            else
              Process.spawn(command, out: wr_out, err: wr_err)
            end
          end

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
                chunk = io.read_nonblock(READ_CHUNK, exception: false)
                case chunk
                when :wait_readable then next
                when nil then readers.delete(io)
                else ((io == rd_out) ? stdout_buf : stderr_buf) << chunk
                end
              end
            end

            [stdout_buf, stderr_buf]
          end

          def kill_process(pid)
            Process.kill("TERM", pid)
            return if Process.waitpid(pid, Process::WNOHANG)

            sleep(KILL_GRACE_SECONDS)
            Process.kill("KILL", pid)

            deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + KILL_GRACE_SECONDS
            loop do
              return if Process.waitpid(pid, Process::WNOHANG)
              break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
              sleep 0.01
            end

            # Uninterruptible-sleep child: nothing more we can do from userspace.
            Process.waitpid(pid)
          rescue Errno::ESRCH, Errno::ECHILD
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
