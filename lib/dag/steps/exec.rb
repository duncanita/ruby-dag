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
        stdin, stdout, stderr, wait_thread = Open3.popen3(command)
        stdin.close

        Timeout.timeout(timeout) { wait_thread.value }
          .then { |status| build_result(stdout.read, stderr.read, status) }
      rescue Timeout::Error
        kill_process(wait_thread)
        Failure.new(error: "Command timed out after #{timeout}s")
      ensure
        close_streams(stdout, stderr)
      end

      def build_result(stdout, stderr, status)
        if status.success?
          Success.new(value: stdout.strip)
        else
          Failure.new(error: "Exit #{status.exitstatus}: #{stderr.strip}")
        end
      end

      def kill_process(wait_thread)
        Process.kill("TERM", wait_thread.pid)
        wait_thread.value
      rescue
        # Process already exited
      end

      def close_streams(*streams)
        streams.compact.each { |io| io.close unless io.closed? }
      end
    end
  end
end
