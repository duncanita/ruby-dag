# frozen_string_literal: true

require "securerandom"

module DAG
  module Adapters
    module Stdlib
      class IdGenerator
        include Ports::IdGenerator

        def initialize
          freeze
        end

        def call = SecureRandom.uuid
      end
    end
  end
end
