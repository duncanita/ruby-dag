# frozen_string_literal: true

module DAG
  module Steps
    class FileWrite
      def call(node, input)
        path = node.config[:path]
        return Failure.new(error: "No path for file_write node #{node.name}") unless path

        content = node.config[:content] || input
        mode = node.config.fetch(:mode, "w")

        File.open(path, mode) { |f| f.write(content) }
        Success.new(value: path)
      rescue => e
        Failure.new(error: "Write error: #{e.message}")
      end
    end
  end
end
