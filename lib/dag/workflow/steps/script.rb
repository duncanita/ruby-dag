# frozen_string_literal: true

require "shellwords"

module DAG
  module Workflow
    module Steps
      class Script
        def call(step, _input)
          path = step.config[:path]
          return Failure.new(error: "No path for script step #{step.name}") unless path

          build_command(path, step.config)
            .then { |cmd, timeout| Exec.new.call(Step.new(name: step.name, type: :exec, command: cmd, timeout: timeout), nil) }
            .then { |result| (result.failure? && result.error.is_a?(Hash) && result.error[:stderr]&.include?("No such file")) ? Failure.new(error: "Script not found: #{path}") : result }
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
end
