# frozen_string_literal: true

module DAG
  module Workflow
    module Steps
      class FileWrite
        VALID_MODES = %w[w a].freeze

        def call(step, input)
          path = step.config[:path]
          return Failure.new(error: "No path for file_write step #{step.name}") unless path

          content = step.config[:content] || input
          mode = step.config.fetch(:mode, "w")
          return Failure.new(error: "Invalid mode '#{mode}' for file_write step #{step.name}. Valid: #{VALID_MODES.join(", ")}") unless VALID_MODES.include?(mode)

          File.open(path, mode) { |f| f.write(content) }
          Success.new(value: path)
        rescue SystemCallError, IOError => e
          Failure.new(error: "Write error: #{e.message}")
        end
      end
    end
  end
end
