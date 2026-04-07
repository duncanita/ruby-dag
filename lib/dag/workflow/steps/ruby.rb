# frozen_string_literal: true

module DAG
  module Workflow
    module Steps
      class Ruby
        def call(step, input)
          callable = step.config[:callable]
          unless callable
            return Failure.new(error: {
              code: :ruby_no_callable,
              message: "ruby step #{step.name} has no :callable config"
            })
          end

          callable.call(input)
        rescue => e
          Result.exception_failure(:ruby_callable_raised, e,
            message: "ruby step #{step.name} callable raised: #{e.message}")
        end
      end
    end
  end
end
