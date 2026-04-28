# frozen_string_literal: true

require "securerandom"

module DAG
  module Adapters
    module Stdlib
      # `DAG::Ports::IdGenerator` adapter backed by `SecureRandom.uuid`.
      # Frozen on construction.
      # @api public
      class IdGenerator
        include Ports::IdGenerator

        def initialize
          freeze
        end

        # @return [String] a fresh UUID
        def call = SecureRandom.uuid
      end
    end
  end
end
