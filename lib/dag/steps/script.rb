# frozen_string_literal: true

require "shellwords"

module DAG
  module Steps
    class Script
      def call(node, _input)
        path = node.config[:path]
        return Failure.new(error: "No path for script node #{node.name}") unless path

        build_command(path, node.config)
          .then { |cmd, timeout| Exec.new.call(Workflow::Step.new(name: node.name, type: :exec, command: cmd, timeout: timeout), nil) }
          .then { |result| (result.failure? && result.error&.include?("No such file")) ? Failure.new(error: "Script not found: #{path}") : result }
      end

      private

      def build_command(path, config)
        args = Array(config[:args]).map { |a| Shellwords.shellescape(a) }.join(" ")
        timeout = config.fetch(:timeout, 60)
        cmd = args.empty? ? "ruby #{Shellwords.shellescape(path)}" : "ruby #{Shellwords.shellescape(path)} #{args}"
        [cmd, timeout]
      end
    end
  end
end
