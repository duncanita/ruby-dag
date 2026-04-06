# frozen_string_literal: true

require "shellwords"

module DAG
  module Workflow
    module Steps
      class RubyScript
        DEFAULT_TIMEOUT = 60

        def call(step, _input)
          path = step.config[:path]
          return Failure.new(error: "No path for ruby_script step #{step.name}") unless path
          return Failure.new(error: "Script not found: #{path}") unless File.exist?(path)

          command = build_command(path, Array(step.config[:args]))
          timeout = step.config.fetch(:timeout, DEFAULT_TIMEOUT)
          Exec.run_command(command, timeout: timeout)
        end

        private

        def build_command(path, args)
          escaped_args = args.map { |a| Shellwords.shellescape(a) }
          ["ruby", Shellwords.shellescape(path), *escaped_args].join(" ")
        end
      end
    end
  end
end
