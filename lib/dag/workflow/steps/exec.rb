# frozen_string_literal: true

require "open3"
require "timeout"

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
          stdout, stderr, status = Timeout.timeout(timeout) {
            Open3.capture3(env, command)
          }
          build_result(command, stdout, stderr, status)
        rescue Timeout::Error
          Failure.new(error: {
            code: :exec_timeout,
            command: command,
            timeout_seconds: timeout
          })
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
