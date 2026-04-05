# frozen_string_literal: true

module DAG
  module Workflow
    module Steps
      class FileRead
        def call(step, _input)
          path = step.config[:path]
          return Failure.new(error: "No path for file_read step #{step.name}") unless path

          Success.new(value: File.read(path))
        rescue Errno::ENOENT
          Failure.new(error: "File not found: #{path}")
        rescue SystemCallError, IOError => e
          Failure.new(error: "Read error: #{e.message}")
        end
      end
    end
  end
end
