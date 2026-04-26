# frozen_string_literal: true

module DAG
  module Adapters
    module Memory
      # In-memory event bus. Single-process, single-thread. Bounded ring
      # buffer — once full, oldest events are dropped. Events read out are
      # always deep-frozen deep-dups; the internal buffer is never exposed.
      class EventBus
        include Ports::EventBus

        DEFAULT_BUFFER_SIZE = 1000

        def initialize(buffer_size: DEFAULT_BUFFER_SIZE)
          @buffer_size = buffer_size
          @events = []
          @subscribers = []
        end

        def publish(event)
          frozen_event = DAG.deep_freeze(DAG.deep_dup(event))
          @events << frozen_event
          @events.shift if @events.size > @buffer_size
          @subscribers.each { |subscriber| subscriber.call(frozen_event) }
          nil
        end

        def subscribe(&block)
          raise ArgumentError, "block required" unless block

          @subscribers << block
          -> { @subscribers.delete(block) }
        end

        def events
          DAG.deep_freeze(DAG.deep_dup(@events))
        end
      end
    end
  end
end
