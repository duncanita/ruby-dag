# frozen_string_literal: true

require "open3"
require "timeout"

module DAG
  module Steps
    class Exec
      def call(node, _input)
        command = node.config[:command]
        return Failure.new(error: "No command for exec node #{node.name}") unless command

        run_command(command, node.config.fetch(:timeout, 30))
      end

      private

      def run_command(command, timeout)
        Timeout.timeout(timeout) { Open3.capture3(command) }
          .then { |stdout, stderr, status| build_result(stdout, stderr, status) }
      rescue Timeout::Error
        Failure.new(error: "Command timed out after #{timeout}s")
      end

      def build_result(stdout, stderr, status)
        if status.success?
          Success.new(value: stdout.strip)
        else
          Failure.new(error: "Exit #{status.exitstatus}: #{stderr.strip}")
        end
      end
    end
  end
end
