# frozen_string_literal: true

module DAG
  module Steps
    class FileRead
      def call(node, _input)
        path = node.config[:path]
        return Failure.new(error: "No path for file_read node #{node.name}") unless path
        return Failure.new(error: "File not found: #{path}") unless File.exist?(path)

        Success.new(value: File.read(path))
      rescue => e
        Failure.new(error: "Read error: #{e.message}")
      end
    end
  end
end
