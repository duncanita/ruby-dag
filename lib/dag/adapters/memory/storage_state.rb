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
            events: {},      # {workflow_id => [event, ...]}
            seq: {}          # {workflow_id => Integer}
          }
        end

        def dispatch(state, method_name, args)
          send(method_name, state, args)
        end

        def fetch_workflow!(state, id)
          state[:workflows].fetch(id) { raise UnknownWorkflowError, "Unknown workflow: #{id}" }
        end

        def fetch_node_states!(state, id, revision)
          state[:node_states].fetch([id, revision]) do
            raise StaleRevisionError, "no node states for #{id} revision #{revision}"
          end
        end

        def create_workflow(state, args)
          id = args.fetch(:id)
          definition = args.fetch(:initial_definition)
          initial_context = args.fetch(:initial_context)
          runtime_profile = args.fetch(:runtime_profile)

          raise ArgumentError, "workflow #{id} already exists" if state[:workflows].key?(id)
          unless definition.is_a?(DAG::Workflow::Definition)
            raise ArgumentError, "initial_definition must be a DAG::Workflow::Definition"
          end
          unless runtime_profile.is_a?(DAG::RuntimeProfile)
            raise ArgumentError, "runtime_profile must be a DAG::RuntimeProfile"
          end
          DAG.json_safe!(initial_context, "$root.initial_context")

          revision = definition.revision
          state[:workflows][id] = {
            id: id,
            state: :pending,
            current_revision: revision,
            runtime_profile: runtime_profile,
            initial_context: initial_context,
            workflow_retry_count: 0
          }
          state[:definitions][[id, revision]] = definition
          state[:node_states][[id, revision]] = definition.nodes.each_with_object({}) { |n, h| h[n] = :pending }
          state[:attempts_index][id] = []
          state[:events][id] = []
          state[:seq][id] = 0
          {id: id, current_revision: revision}
        end

        def load_workflow(state, args)
          id = args.fetch(:id)
          fetch_workflow!(state, id).dup
        end

        def transition_workflow_state(state, args)
          id = args.fetch(:id)
          from = args.fetch(:from)
          to = args.fetch(:to)
          row = fetch_workflow!(state, id)
          unless row[:state] == from
            raise StaleStateError, "workflow #{id} state is #{row[:state].inspect}, expected #{from.inspect}"
          end
          row[:state] = to
          {id: id, state: to}
        end

        def increment_workflow_retry(state, args)
          id = args.fetch(:id)
          row = fetch_workflow!(state, id)
          row[:workflow_retry_count] += 1
          {id: id, workflow_retry_count: row[:workflow_retry_count]}
        end

        def reset_failed_nodes(state, args)
          id = args.fetch(:id)
          revision = args.fetch(:revision)
          states_for_rev = fetch_node_states!(state, id, revision)
          # Snapshot the failed node ids before mutating; iterating a Hash
          # while reassigning values is technically safe in Ruby but the
          # snapshot makes the intent obvious and survives future edits.
          failed_node_ids = states_for_rev.select { |_, s| s == :failed }.keys
          # Abort prior :failed attempts so the per-node attempt counter
          # restarts from 1 on the next run. count_attempts excludes
          # :aborted attempts.
          failed_node_ids.each do |node_id|
            states_for_rev[node_id] = :pending
            state[:attempts_index].fetch(id, []).each do |aid|
              attempt = state[:attempts][aid]
              next unless attempt[:revision] == revision && attempt[:node_id] == node_id
              attempt[:state] = :aborted if attempt[:state] == :failed
            end
          end
          {id: id, revision: revision, reset: failed_node_ids}
        end

        def append_revision(state, args)
          id = args.fetch(:id)
          parent_revision = args.fetch(:parent_revision)
          definition = args.fetch(:definition)
          invalidated_node_ids = args.fetch(:invalidated_node_ids, []).map(&:to_sym)

          row = fetch_workflow!(state, id)
          unless row[:current_revision] == parent_revision
            raise StaleRevisionError,
              "workflow #{id} current_revision is #{row[:current_revision]}, expected #{parent_revision}"
          end

          new_revision = parent_revision + 1
          state[:definitions][[id, new_revision]] = definition

          previous_states = state[:node_states][[id, parent_revision]] || {}
          new_states = definition.nodes.each_with_object({}) do |node_id, acc|
            acc[node_id] = if invalidated_node_ids.include?(node_id) || !previous_states.key?(node_id)
              :pending
            else
              previous_states[node_id]
            end
          end
          state[:node_states][[id, new_revision]] = new_states
          row[:current_revision] = new_revision
          {id: id, revision: new_revision}
        end

        def load_revision(state, args)
          id = args.fetch(:id)
          revision = args.fetch(:revision)
          state[:definitions].fetch([id, revision]) do
            raise StaleRevisionError, "no revision #{revision} for #{id}"
          end
        end

        def load_current_definition(state, args)
          id = args.fetch(:id)
          row = fetch_workflow!(state, id)
          state[:definitions].fetch([id, row[:current_revision]])
        end

        def load_node_states(state, args)
          id = args.fetch(:workflow_id)
          revision = args.fetch(:revision)
          fetch_node_states!(state, id, revision).dup
        end

        def transition_node_state(state, args)
          id = args.fetch(:workflow_id)
          revision = args.fetch(:revision)
          node_id = args.fetch(:node_id)
          from = args.fetch(:from)
          to = args.fetch(:to)

          states_for_rev = fetch_node_states!(state, id, revision)
          current = states_for_rev[node_id]
          unless current == from
            raise StaleStateError, "node #{node_id} state is #{current.inspect}, expected #{from.inspect}"
          end
          states_for_rev[node_id] = to
          {workflow_id: id, revision: revision, node_id: node_id, state: to}
        end

        # Pure writer: caller supplies attempt_number (Roadmap §R1 lines
        # 522-525). The adapter does not own the numbering rule; this lets
        # SQLite share one transaction between count + insert in S0.
        def begin_attempt(state, args)
          id = args.fetch(:workflow_id)
          revision = args.fetch(:revision)
          node_id = args.fetch(:node_id)
          attempt_number = args.fetch(:attempt_number)
          expected = args.fetch(:expected_node_state)

          states_for_rev = fetch_node_states!(state, id, revision)
          current = states_for_rev[node_id]
          unless current == expected
            raise StaleStateError, "node #{node_id} state is #{current.inspect}, expected #{expected.inspect}"
          end

          # Format is opaque; consumers must not parse it.
          attempt_id = "#{id}/#{revision}/#{node_id}/#{attempt_number}"

          states_for_rev[node_id] = :running
          state[:attempts][attempt_id] = {
            attempt_id: attempt_id,
            workflow_id: id,
            revision: revision,
            node_id: node_id,
            attempt_number: attempt_number,
            state: :running,
            result: nil,
            started_at_ms: nil,
            finished_at_ms: nil
          }
          state[:attempts_index][id] << attempt_id
          attempt_id
        end

        def commit_attempt(state, args)
          attempt_id = args.fetch(:attempt_id)
          result = args.fetch(:result)
          node_state = args.fetch(:node_state)

          attempt = state[:attempts].fetch(attempt_id) do
            raise ArgumentError, "Unknown attempt: #{attempt_id}"
          end
          attempt[:result] = result
          attempt[:state] = attempt_terminal_state_for(result)
          attempt[:finished_at_ms] = args[:finished_at_ms]

          rev_states = state[:node_states][[attempt[:workflow_id], attempt[:revision]]]
          rev_states[attempt[:node_id]] = node_state

          {attempt_id: attempt_id, state: attempt[:state], node_state: node_state}
        end

        def abort_running_attempts(state, args)
          id = args.fetch(:workflow_id)
          aborted = []
          state[:attempts_index].fetch(id, []).each do |attempt_id|
            attempt = state[:attempts][attempt_id]
            if attempt[:state] == :running
              attempt[:state] = :aborted
              aborted << attempt_id
            end
          end
          aborted
        end

        def list_attempts(state, args)
          id = args.fetch(:workflow_id)
          revision = args[:revision]
          node_id = args[:node_id]
          state[:attempts_index].fetch(id, []).map { |aid| state[:attempts][aid] }.select do |attempt|
            (revision.nil? || attempt[:revision] == revision) &&
              (node_id.nil? || attempt[:node_id] == node_id)
          end
        end

        def count_attempts(state, args)
          id = args.fetch(:workflow_id)
          revision = args.fetch(:revision)
          node_id = args.fetch(:node_id)
          count_attempts_internal(state, id, revision, node_id, exclude: [:aborted])
        end

        def append_event(state, args)
          id = args.fetch(:workflow_id)
          event = args.fetch(:event)
          state[:seq][id] ||= 0
          state[:seq][id] += 1
          stamped = event.with(seq: state[:seq][id])
          state[:events][id] ||= []
          state[:events][id] << stamped
          stamped
        end

        def read_events(state, args)
          id = args.fetch(:workflow_id)
          after_seq = args[:after_seq]
          limit = args[:limit]
          events = state[:events].fetch(id, [])
          filtered = after_seq ? events.select { |e| e.seq > after_seq } : events.dup
          limit ? filtered.first(limit) : filtered
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
