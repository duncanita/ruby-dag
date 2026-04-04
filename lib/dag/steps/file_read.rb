# frozen_string_literal: true

module DAG
  module Steps
    class FileRead
      def call(node, _input)
        path = node.config[:path]
        return Failure.new(error: "No path for file_read node #{node.name}") unless path

        Success.new(value: File.read(path))
      rescue Errno::ENOENT
        Failure.new(error: "File not found: #{path}")
      rescue SystemCallError, IOError => e
        Failure.new(error: "Read error: #{e.message}")
      end
    end
  end
end
