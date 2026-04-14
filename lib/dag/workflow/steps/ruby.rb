# frozen_string_literal: true

module DAG
  module Workflow
    module Steps
      class Ruby
        def call(step, input, context: nil)
          callable = step.config[:callable]
          unless callable
            return Failure.new(error: {
              code: :ruby_no_callable,
              message: "ruby step #{step.name} has no :callable config"
            })
          end

          invoke_callable(callable, input, context)
        rescue => e
          Result.exception_failure(:ruby_callable_raised, e,
            message: "ruby step #{step.name} callable raised: #{e.message}")
        end

        private

        def invoke_callable(callable, input, context)
          if accepts_context?(callable)
            callable.call(input, context)
          else
            callable.call(input)
          end
        end

        def accepts_context?(callable)
          parameters = callable.parameters
          positional = parameters.count { |kind, _name| [:req, :opt].include?(kind) }
          positional >= 2 || parameters.any? { |kind, _name| kind == :rest }
        end
      end
    end
  end
end
