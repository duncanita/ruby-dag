# frozen_string_literal: true

module DAG
  # Pure value layer for abstract external side effects. Effects are described
  # as immutable intents; execution and durability live behind later ports.
  # @api public
  module Effects
    # Durable effect states shared by records and handler results.
    STATUSES = %i[
      reserved
      dispatching
      succeeded
      failed_retriable
      failed_terminal
    ].freeze

    # Terminal effect states.
    TERMINAL_STATUSES = %i[succeeded failed_terminal].freeze

    module_function

    # Assert an Array contains only effect intents.
    # @param proposed_effects [Array<DAG::Effects::Intent>]
    # @param label [String]
    # @return [Array<DAG::Effects::Intent>]
    def validate_intents!(proposed_effects, label: "proposed_effects")
      raise ArgumentError, "#{label} must be an Array" unless proposed_effects.is_a?(Array)

      proposed_effects.each_with_index do |intent, index|
        next if intent.is_a?(DAG::Effects::Intent)

        raise ArgumentError,
          "#{label}[#{index}] must be DAG::Effects::Intent, got #{intent.class}"
      end
      proposed_effects
    end

    # Effect refs use `type:key`; disallow the separator in either component
    # so the string ref remains an unambiguous representation of identity.
    # @api private
    def validate_ref_part!(value, label)
      raise ArgumentError, "#{label} must be String" unless value.is_a?(String)
      raise ArgumentError, "#{label} must not include ':'" if value.include?(":")
    end

    # @api private
    def ref_for(type, key)
      "#{type}:#{key}".freeze
    end

    # Fetch a value from a Hash-like snapshot accepting symbol or string keys.
    # @api private
    def fetch_snapshot_value(snapshot, key, default = nil)
      return default if snapshot.nil?
      return snapshot.fetch(key) { snapshot.fetch(key.to_s, default) } if snapshot.is_a?(Hash)
      return snapshot.public_send(key) if snapshot.respond_to?(key)

      default
    end

    # Fetch a required value from a Hash-like snapshot accepting symbol or
    # string keys.
    # @api private
    def fetch_required_snapshot_value(snapshot, key)
      if snapshot.is_a?(Hash)
        return snapshot.fetch(key) if snapshot.key?(key)
        return snapshot.fetch(key.to_s) if snapshot.key?(key.to_s)
      end
      return snapshot.public_send(key) if snapshot.respond_to?(key)

      raise KeyError, "missing effect snapshot key: #{key}"
    end
  end
end

require_relative "effects/idempotency_conflict_error"
require_relative "effects/stale_lease_error"
require_relative "effects/unknown_effect_error"
require_relative "effects/unknown_handler_error"
require_relative "effects/intent"
require_relative "effects/prepared_intent"
require_relative "effects/record"
require_relative "effects/handler_result"
require_relative "effects/dispatch_report"
require_relative "effects/dispatcher"
require_relative "effects/await"
