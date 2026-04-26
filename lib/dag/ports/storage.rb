# frozen_string_literal: true

module DAG
  module Ports
    module Storage
      def create_workflow(id:, initial_definition:, initial_context:, runtime_profile:)
        raise PortNotImplementedError
      end

      def load_workflow(id:)
        raise PortNotImplementedError
      end

      def transition_workflow_state(id:, from:, to:)
        raise PortNotImplementedError
      end

      def append_revision(id:, parent_revision:, definition:, invalidated_node_ids:, event:)
        raise PortNotImplementedError
      end

      def load_revision(id:, revision:)
        raise PortNotImplementedError
      end

      def load_current_definition(id:)
        raise PortNotImplementedError
      end

      def load_node_states(workflow_id:, revision:)
        raise PortNotImplementedError
      end

      def transition_node_state(workflow_id:, revision:, node_id:, from:, to:)
        raise PortNotImplementedError
      end

      def begin_attempt(workflow_id:, revision:, node_id:, attempt_number:, expected_node_state:)
        raise PortNotImplementedError
      end

      # Atomic write: result + node_state transition + event append.
      # Returns {attempt_id:, state:, node_state:, event:} where :event is
      # the seq-stamped Event the storage wrote, ready for EventBus#publish.
      def commit_attempt(attempt_id:, result:, node_state:, event:, finished_at_ms: nil)
        raise PortNotImplementedError
      end

      def abort_running_attempts(workflow_id:)
        raise PortNotImplementedError
      end

      def list_attempts(workflow_id:, revision: nil, node_id: nil)
        raise PortNotImplementedError
      end

      def count_attempts(workflow_id:, revision:, node_id:)
        raise PortNotImplementedError
      end

      # Returns the most recent attempt record for (workflow, revision, node)
      # whose state is :committed, or nil if there isn't one. Lets adapters
      # answer the runner's per-predecessor effective-context lookup with a
      # single record instead of the full attempt history.
      def latest_committed_attempt(workflow_id:, revision:, node_id:)
        raise PortNotImplementedError
      end

      def append_event(workflow_id:, event:)
        raise PortNotImplementedError
      end

      def read_events(workflow_id:, after_seq: nil, limit: nil)
        raise PortNotImplementedError
      end

      # Returns the seq of the most recent event for the workflow, or nil if
      # there are no events. Cheaper than reading the whole log just to take
      # `events.last&.seq`.
      def last_event_seq(workflow_id:)
        raise PortNotImplementedError
      end
    end
  end
end
