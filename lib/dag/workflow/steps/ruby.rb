# frozen_string_literal: true

module DAG
  module Workflow
    module Steps
      class Ruby
        def call(step, input)
          callable = step.config[:callable]
          return Failure.new(error: "No callable for ruby step #{step.name}") unless callable

          callable.call(input)
        rescue => e
          Failure.new(error: "Ruby error: #{e.class}: #{e.message}")
        end
      end
    end
  end
end
