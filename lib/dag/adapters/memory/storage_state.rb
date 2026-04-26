# frozen_string_literal: true

module DAG
  module Adapters
    module Memory
      # Mutable bookkeeping module for `Memory::Storage`. This is the only
      # spot in `lib/dag/**` allowed to mutate hashes in place — the cop
      # path-allowlists `lib/dag/adapters/memory/**`. The facade always
      # deep-dups returns, so callers never see a mutable reference.
      module StorageState
        module_function

        def fresh_state
          {
            workflows: {},
            definitions: {}, # {[workflow_id, revision] => Definition}
            node_states: {}, # {[workflow_id, revision] => {node_id => state}}
            attempts: {},    # {attempt_id => attempt_record}
            attempts_index: {}, # {workflow_id => [attempt_id, ...]}
            attempt_seq: {}, # {workflow_id => Integer} monotonic, never reset
            events: {},      # {workflow_id => [event, ...]}
            seq: {}          # {workflow_id => Integer} event seq
          }
        end

        def fetch_workflow!(state, id)
          state[:workflows].fetch(id) { raise UnknownWorkflowError, "Unknown workflow: #{id}" }
        end

        def fetch_node_states!(state, id, revision)
          state[:node_states].fetch([id, revision]) do
            raise StaleRevisionError, "no node states for #{id} revision #{revision}"
          end
        end

        def create_workflow(state, id:, initial_definition:, initial_context:, runtime_profile:)
          raise ArgumentError, "workflow #{id} already exists" if state[:workflows].key?(id)
          unless initial_definition.is_a?(DAG::Workflow::Definition)
            raise ArgumentError, "initial_definition must be a DAG::Workflow::Definition"
          end
          unless runtime_profile.is_a?(DAG::RuntimeProfile)
            raise ArgumentError, "runtime_profile must be a DAG::RuntimeProfile"
          end
          DAG.json_safe!(initial_context, "$root.initial_context")

          revision = initial_definition.revision
          state[:workflows][id] = {
            id: id,
            state: :pending,
            current_revision: revision,
            runtime_profile: runtime_profile,
            initial_context: DAG.frozen_copy(initial_context),
            workflow_retry_count: 0
          }
          state[:definitions][[id, revision]] = initial_definition
          state[:node_states][[id, revision]] = initial_definition.nodes.each_with_object({}) { |n, h| h[n] = :pending }
          state[:attempts_index][id] = []
          state[:attempt_seq][id] = 0
          state[:events][id] = []
          state[:seq][id] = 0
          {id: id, current_revision: revision}
        end

        def load_workflow(state, id:)
          fetch_workflow!(state, id).dup
        end

        def transition_workflow_state(state, id:, from:, to:)
          row = fetch_workflow!(state, id)
          unless row[:state] == from
            raise StaleStateError, "workflow #{id} state is #{row[:state].inspect}, expected #{from.inspect}"
          end
          row[:state] = to
          {id: id, state: to}
        end

        def append_revision(state, id:, parent_revision:, definition:, invalidated_node_ids:, event:)
          row = fetch_workflow!(state, id)
          unless row[:current_revision] == parent_revision
            raise StaleRevisionError,
              "workflow #{id} current_revision is #{row[:current_revision]}, expected #{parent_revision}"
          end

          new_revision = parent_revision + 1
          stored_definition = (definition.revision == new_revision) ? definition : definition.with_revision(new_revision)
          state[:definitions][[id, new_revision]] = stored_definition

          previous_states = state[:node_states][[id, parent_revision]] || {}
          invalidated = invalidated_node_ids.map(&:to_sym)
          new_states = stored_definition.nodes.each_with_object({}) do |node_id, acc|
            acc[node_id] = if invalidated.include?(node_id) || !previous_states.key?(node_id)
              :pending
            else
              previous_states[node_id]
            end
          end
          state[:node_states][[id, new_revision]] = new_states
          row[:current_revision] = new_revision
          {id: id, revision: new_revision}
        end

        def load_revision(state, id:, revision:)
          state[:definitions].fetch([id, revision]) do
            raise StaleRevisionError, "no revision #{revision} for #{id}"
          end
        end

        def load_current_definition(state, id:)
          row = fetch_workflow!(state, id)
          state[:definitions].fetch([id, row[:current_revision]])
        end

        def load_node_states(state, workflow_id:, revision:)
          fetch_node_states!(state, workflow_id, revision).dup
        end

        def transition_node_state(state, workflow_id:, revision:, node_id:, from:, to:)
          states_for_rev = fetch_node_states!(state, workflow_id, revision)
          current = states_for_rev[node_id]
          unless current == from
            raise StaleStateError, "node #{node_id} state is #{current.inspect}, expected #{from.inspect}"
          end
          states_for_rev[node_id] = to
          {workflow_id: workflow_id, revision: revision, node_id: node_id, state: to}
        end

        def begin_attempt(state, workflow_id:, revision:, node_id:, expected_node_state:)
          states_for_rev = fetch_node_states!(state, workflow_id, revision)
          current = states_for_rev[node_id]
          unless current == expected_node_state
            raise StaleStateError, "node #{node_id} state is #{current.inspect}, expected #{expected_node_state.inspect}"
          end

          state[:attempt_seq][workflow_id] += 1
          attempt_id = "#{workflow_id}/#{state[:attempt_seq][workflow_id]}"
          attempt_number = count_attempts_internal(state, workflow_id, revision, node_id, exclude: [:aborted]) + 1

          states_for_rev[node_id] = :running
          state[:attempts][attempt_id] = {
            attempt_id: attempt_id,
            workflow_id: workflow_id,
            revision: revision,
            node_id: node_id,
            attempt_number: attempt_number,
            state: :running,
            result: nil
          }
          state[:attempts_index][workflow_id] << attempt_id
          attempt_id
        end

        def commit_attempt(state, attempt_id:, result:, node_state:, event:)
          attempt = state[:attempts].fetch(attempt_id) do
            raise ArgumentError, "Unknown attempt: #{attempt_id}"
          end
          attempt[:result] = result
          attempt[:state] = attempt_terminal_state_for(result)

          rev_states = state[:node_states][[attempt[:workflow_id], attempt[:revision]]]
          rev_states[attempt[:node_id]] = node_state

          append_event_internal(state, attempt[:workflow_id], event)
        end

        def abort_running_attempts(state, workflow_id:)
          row = fetch_workflow!(state, workflow_id)
          current_revision = row[:current_revision]
          current_states = fetch_node_states!(state, workflow_id, current_revision)
          aborted = []
          state[:attempts_index].fetch(workflow_id, []).each do |attempt_id|
            attempt = state[:attempts][attempt_id]
            next unless attempt[:state] == :running

            attempt[:state] = :aborted
            aborted << attempt_id

            next unless attempt[:revision] == current_revision
            next unless current_states[attempt[:node_id]] == :running

            current_states[attempt[:node_id]] = :pending
          end
          aborted
        end

        def list_attempts(state, workflow_id:, revision: nil, node_id: nil)
          state[:attempts_index].fetch(workflow_id, []).map { |aid| state[:attempts][aid] }.select do |attempt|
            (revision.nil? || attempt[:revision] == revision) &&
              (node_id.nil? || attempt[:node_id] == node_id)
          end
        end

        def count_attempts(state, workflow_id:, revision:, node_id:)
          count_attempts_internal(state, workflow_id, revision, node_id, exclude: [:aborted])
        end

        def append_event(state, workflow_id:, event:)
          append_event_internal(state, workflow_id, event)
        end

        def append_event_internal(state, workflow_id, event)
          state[:seq][workflow_id] ||= 0
          state[:seq][workflow_id] += 1
          stamped = event.with(seq: state[:seq][workflow_id])
          state[:events][workflow_id] ||= []
          state[:events][workflow_id] << stamped
          stamped
        end

        def read_events(state, workflow_id:, after_seq: nil, limit: nil)
          events = state[:events].fetch(workflow_id, [])
          events = events.select { |e| e.seq > after_seq } if after_seq
          events = events.first(limit) if limit
          events
        end

        # Port extension. Atomic: abort prior :failed attempts, reset their
        # nodes to :pending, increment workflow_retry_count.
        def prepare_workflow_retry(state, id:)
          row = fetch_workflow!(state, id)
          revision = row[:current_revision]
          states_for_rev = fetch_node_states!(state, id, revision)
          failed_node_ids = states_for_rev.select { |_, s| s == :failed }.keys

          failed_set = failed_node_ids.to_set
          state[:attempts_index].fetch(id, []).each do |aid|
            attempt = state[:attempts][aid]
            next unless attempt[:revision] == revision && failed_set.include?(attempt[:node_id])
            attempt[:state] = :aborted if attempt[:state] == :failed
          end
          failed_node_ids.each { |node_id| states_for_rev[node_id] = :pending }
          row[:workflow_retry_count] += 1

          {reset: failed_node_ids, workflow_retry_count: row[:workflow_retry_count]}
        end

        def count_attempts_internal(state, id, revision, node_id, exclude: [])
          state[:attempts_index].fetch(id, []).count do |aid|
            a = state[:attempts][aid]
            a[:revision] == revision && a[:node_id] == node_id && !exclude.include?(a[:state])
          end
        end

        def attempt_terminal_state_for(result)
          case result
          when DAG::Success then :committed
          when DAG::Waiting then :waiting
          when DAG::Failure then :failed
          else
            raise ArgumentError, "unexpected attempt result type: #{result.class}"
          end
        end
      end
    end
  end
end
