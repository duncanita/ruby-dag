# frozen_string_literal: true

module DAG
  module Workflow
    class RetryMiddleware < StepMiddleware
      DEFAULT_BACKOFF = :fixed

      def initialize(clock: Clock.new, sleeper: nil)
        @clock = clock
        @sleeper = sleeper || ->(seconds) { sleep(seconds) }
      end

      def call(step, input, context:, execution:, next_step:)
        config = normalize_config(step.config[:retry])
        return next_step.call(step, input, context: context, execution: execution) unless config

        errors = []
        attempt = 1

        loop do
          attempt_execution = execution.with(attempt: attempt)
          result = next_step.call(step, input, context: context, execution: attempt_execution)
          return result if result.success?

          current_error = result.error
          errors << current_error

          return failure_with_attempt_errors(current_error, errors) unless retryable?(current_error, config[:retry_on])
          return failure_with_attempt_errors(current_error, errors) if attempt >= config[:max_attempts]

          delay = compute_delay(config, attempt)
          return workflow_timeout_failure(step, errors) if deadline_exceeded?(execution.deadline, delay)

          @sleeper.call(delay)
          attempt += 1
        end
      end

      private

      def normalize_config(config)
        return nil unless config

        cfg = config.transform_keys(&:to_sym)
        max_attempts = Integer(cfg.fetch(:max_attempts, 1))
        return nil if max_attempts <= 1

        {
          max_attempts: max_attempts,
          backoff: (cfg[:backoff] || DEFAULT_BACKOFF).to_sym,
          base_delay: Float(cfg.fetch(:base_delay, 0.0)),
          max_delay: cfg.key?(:max_delay) ? Float(cfg[:max_delay]) : nil,
          retry_on: cfg[:retry_on]&.map(&:to_sym)
        }
      end

      def retryable?(error, retry_on)
        return false unless error.is_a?(Hash)
        return true if retry_on.nil? || retry_on.empty?

        retry_on.include?(error[:code])
      end

      def compute_delay(config, attempt)
        retry_index = attempt
        base = config[:base_delay]

        delay = case config[:backoff]
        when :fixed
          base
        when :linear
          base * retry_index
        when :exponential
          base * (2**(retry_index - 1))
        else
          raise ArgumentError, "Unknown retry backoff: #{config[:backoff].inspect}"
        end

        config[:max_delay] ? [delay, config[:max_delay]].min : delay
      end

      def deadline_exceeded?(deadline, delay)
        deadline && (@clock.monotonic_now + delay) >= deadline
      end

      def workflow_timeout_failure(step, errors)
        Failure.new(error: {
          code: :workflow_timeout,
          message: "retry backoff for step #{step.name} exceeded workflow deadline",
          attempt_errors: errors
        })
      end

      def failure_with_attempt_errors(error, errors)
        return Failure.new(error: error.merge(attempt_errors: errors)) if error.is_a?(Hash)

        Failure.new(error: {code: :retry_failed, message: error.to_s, attempt_errors: errors})
      end
    end
  end
end
