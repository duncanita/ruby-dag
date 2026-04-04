# frozen_string_literal: true

module DAG
  module Steps
    class Ruby
      def call(node, input)
        callable = node.config[:callable]
        return Failure.new(error: "No callable for ruby node #{node.name}") unless callable

        callable.call(input)
      rescue => e
        Failure.new(error: "Ruby error: #{e.class}: #{e.message}")
      end
    end
  end
end
