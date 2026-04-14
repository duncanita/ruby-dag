# frozen_string_literal: true

module DAG
  module Workflow
    module Steps
      # Reads the file at `step.config[:path]` and returns its contents as a
      # Success value. No path sandboxing is applied — the caller is
      # responsible for validating paths if workflow definitions come from
      # untrusted sources.
      class FileRead
        def call(step, _input)
          path = step.config[:path]
          unless path
            return Failure.new(error: {
              code: :file_read_no_path,
              message: "file_read step #{step.name} has no :path config"
            })
          end

          Success.new(value: File.read(path))
        rescue Errno::ENOENT
          Failure.new(error: {
            code: :file_read_not_found,
            message: "file_read step #{step.name}: file not found at #{path}",
            path: path
          })
        rescue SystemCallError, IOError => e
          Result.exception_failure(:file_read_io_error, e,
            message: "file_read step #{step.name}: #{e.message}",
            path: path)
        end
      end
    end
  end
end
