# frozen_string_literal: true

module DAG
  module Workflow
    module Steps
      class Exec
        def call(step, _input)
          command = step.config[:command]
          return Failure.new(error: "No command for exec step #{step.name}") unless command

          run_command(command, step.config.fetch(:timeout, 30))
        end

        def run_with_env(command, env, timeout)
          run_command(command, timeout, env: env)
        end

        private

        def run_command(command, timeout, env: {})
          rd_out, wr_out = IO.pipe
          rd_err, wr_err = IO.pipe
          pid = nil

          pid = Process.spawn(env, command, out: wr_out, err: wr_err)
          wr_out.close
          wr_err.close

          stdout, stderr = drain_pipes(rd_out, rd_err, timeout)

          if stdout.nil?
            kill_process(pid)
            pid = nil
            return Failure.new(error: {
              code: :exec_timeout,
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
              chunk = io.read_nonblock(16384, exception: false)
              case chunk
              when :wait_readable
                next
              when nil
                readers.delete(io)
              else
                ((io == rd_out) ? stdout_buf : stderr_buf) << chunk
              end
            end
          end

          [stdout_buf, stderr_buf]
        end

        def kill_process(pid)
          Process.kill("TERM", pid)
          Process.waitpid(pid, Process::WNOHANG) && return
          sleep(0.1)
          Process.kill("KILL", pid)
          Process.waitpid(pid)
        rescue Errno::ESRCH, Errno::ECHILD
          # process already exited or reaped
        end

        def build_result(command, stdout, stderr, status)
          if status.success?
            Success.new(value: stdout.strip)
          else
            Failure.new(error: {
              code: :exec_failed,
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
