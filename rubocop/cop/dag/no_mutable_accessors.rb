# frozen_string_literal: true

require "rubocop"

module RuboCop
  module Cop
    module DAG
      class NoMutableAccessors < Base
        MSG = "Do not expose mutable writers from lib/dag runtime objects."
        RESTRICT_ON_SEND = %i[attr_accessor attr_writer].freeze

        def on_send(node)
          add_offense(node) if runtime_file?
        end

        private

        def runtime_file?
          path = processed_source.file_path
          path.include?("/lib/dag/") || path.end_with?("/lib/dag.rb")
        end
      end
    end
  end
end
