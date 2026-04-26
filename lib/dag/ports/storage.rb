# frozen_string_literal: true

module DAG
  module Ports
    # Storage port — 15 documented methods (Roadmap v3.4 §C / Appendix I)
    # plus 1 documented extension (`prepare_workflow_retry`) needed for
    # `Runner#retry_workflow` per R1 DoD. Adapters must implement all 16.
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

      def begin_attempt(workflow_id:, revision:, node_id:, expected_node_state:)
        raise PortNotImplementedError
      end

      def commit_attempt(attempt_id:, result:, node_state:, event:)
        raise PortNotImplementedError
      end

      # Abort in-flight attempts for a workflow before resume. Adapters must
      # also reset any corresponding current-revision node still in :running
      # back to :pending so eligibility can recompute from committed state.
      def abort_running_attempts(workflow_id:)
        raise PortNotImplementedError
      end

      def list_attempts(workflow_id:, revision: nil, node_id: nil)
        raise PortNotImplementedError
      end

      def count_attempts(workflow_id:, revision:, node_id:)
        raise PortNotImplementedError
      end

      def append_event(workflow_id:, event:)
        raise PortNotImplementedError
      end

      def read_events(workflow_id:, after_seq: nil, limit: nil)
        raise PortNotImplementedError
      end

      # Port extension (see CLAUDE.md "Port extensions"). Atomically:
      # (a) find :failed nodes for the workflow's current revision,
      # (b) mark each corresponding :failed attempt as :aborted,
      # (c) transition those nodes back to :pending,
      # (d) increment the workflow's retry-count tracking.
      # Returns {reset: [node_id, ...], workflow_retry_count: Integer}.
      def prepare_workflow_retry(id:)
        raise PortNotImplementedError
      end
    end
  end
end
