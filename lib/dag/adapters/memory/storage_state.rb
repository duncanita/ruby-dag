# frozen_string_literal: true

module DAG
  module Adapters
    module Memory
      # Mutable bookkeeping module for `Memory::Storage`. This is the only
      # spot in `lib/dag/**` allowed to mutate hashes in place — the cop
      # path-allowlists `lib/dag/adapters/memory/**`. The facade always
      # deep-dups returns, so callers never see a mutable reference.
      # @!visibility private
      # @api private
      module StorageState
        module_function

        # Internal initial state hash.
        # @api private
        def fresh_state
          {
            workflows: {},
            definitions: {}, # {[workflow_id, revision] => Definition}
            node_states: {}, # {[workflow_id, revision] => {node_id => state}}
            attempts: {},    # {attempt_id => attempt_record}
            attempts_index: {}, # {workflow_id => [attempt_id, ...]}
            attempt_seq: {}, # {workflow_id => Integer} monotonic, never reset
            effects: {}, # {effect_id => DAG::Effects::Record}
            effects_by_ref: {}, # {ref => effect_id}
            effect_order: [], # [effect_id, ...] insertion order for deterministic claims
            effect_seq: 0, # global effect id sequence
            attempt_effect_links: {}, # {attempt_id => [effect_link, ...]}
            node_effect_links: {}, # {[workflow_id, revision, node_id] => [effect_link, ...]}
            events: {},      # {workflow_id => [event, ...]}
            seq: {}          # {workflow_id => Integer} event seq
          }
        end

        # Internal: lookup-or-raise for a workflow row.
        # @api private
        def fetch_workflow!(state, id)
          state[:workflows].fetch(id) { raise UnknownWorkflowError, "Unknown workflow: #{id}" }
        end

        # Internal: lookup-or-raise for a revision's node-state map.
        # @api private
        def fetch_node_states!(state, id, revision)
          state[:node_states].fetch([id, revision]) do
            raise StaleRevisionError, "no node states for #{id} revision #{revision}"
          end
        end

        # Internal: initialize effect-ledger keys for snapshots created before
        # the effect-aware storage extension existed.
        # @api private
        def ensure_effect_state!(state)
          state[:effects] ||= {}
          state[:effects_by_ref] ||= {}
          state[:effect_order] ||= state[:effects].keys
          state[:effect_seq] ||= state[:effects].size
          state[:attempt_effect_links] ||= {}
          state[:node_effect_links] ||= {}
        end

        # Implements `Ports::Storage#create_workflow`.
        # @api private
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

        # Implements `Ports::Storage#load_workflow`.
        # @api private
        def load_workflow(state, id:)
          fetch_workflow!(state, id).dup
        end

        # Implements `Ports::Storage#transition_workflow_state`.
        # @api private
        def transition_workflow_state(state, id:, from:, to:, event: nil)
          row = fetch_workflow!(state, id)
          unless row[:state] == from
            raise StaleStateError, "workflow #{id} state is #{row[:state].inspect}, expected #{from.inspect}"
          end
          row[:state] = to
          stamped = event ? append_event_internal(state, id, event) : nil
          {id: id, state: to, event: stamped}
        end

        # Implements `Ports::Storage#append_revision`.
        # @api private
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
            acc[node_id] = if invalidated.include?(node_id)
              :invalidated
            elsif !previous_states.key?(node_id)
              :pending
            else
              previous_states[node_id]
            end
          end
          state[:node_states][[id, new_revision]] = new_states
          row[:current_revision] = new_revision
          stamped = event ? append_event_internal(state, id, event) : nil
          {id: id, revision: new_revision, event: stamped}
        end

        # Implements `Ports::Storage#append_revision_if_workflow_state`.
        # @api private
        def append_revision_if_workflow_state(state, id:, allowed_states:, parent_revision:, definition:, invalidated_node_ids:, event:)
          row = fetch_workflow!(state, id)
          validate_workflow_state_for_revision_append!(id, row.fetch(:state), allowed_states)
          append_revision(
            state,
            id: id,
            parent_revision: parent_revision,
            definition: definition,
            invalidated_node_ids: invalidated_node_ids,
            event: event
          )
        end

        # Implements `Ports::Storage#load_revision`.
        # @api private
        def load_revision(state, id:, revision:)
          state[:definitions].fetch([id, revision]) do
            raise StaleRevisionError, "no revision #{revision} for #{id}"
          end
        end

        # Implements `Ports::Storage#load_current_definition`.
        # @api private
        def load_current_definition(state, id:)
          row = fetch_workflow!(state, id)
          state[:definitions].fetch([id, row[:current_revision]])
        end

        # Implements `Ports::Storage#load_node_states`.
        # @api private
        def load_node_states(state, workflow_id:, revision:)
          fetch_node_states!(state, workflow_id, revision).dup
        end

        # Implements `Ports::Storage#transition_node_state`.
        # @api private
        def transition_node_state(state, workflow_id:, revision:, node_id:, from:, to:)
          states_for_rev = fetch_node_states!(state, workflow_id, revision)
          current = states_for_rev[node_id]
          unless current == from
            raise StaleStateError, "node #{node_id} state is #{current.inspect}, expected #{from.inspect}"
          end
          states_for_rev[node_id] = to
          {workflow_id: workflow_id, revision: revision, node_id: node_id, state: to}
        end

        # Implements `Ports::Storage#begin_attempt`.
        # @api private
        def begin_attempt(state, workflow_id:, revision:, node_id:, expected_node_state:, attempt_number:)
          unless attempt_number.is_a?(Integer) && attempt_number.positive?
            raise ArgumentError, "attempt_number must be a positive Integer"
          end

          states_for_rev = fetch_node_states!(state, workflow_id, revision)
          current = states_for_rev[node_id]
          unless current == expected_node_state
            raise StaleStateError, "node #{node_id} state is #{current.inspect}, expected #{expected_node_state.inspect}"
          end

          state[:attempt_seq][workflow_id] += 1
          attempt_id = "#{workflow_id}/#{state[:attempt_seq][workflow_id]}"

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

        # Implements `Ports::Storage#commit_attempt`.
        # @api private
        def commit_attempt(state, attempt_id:, result:, node_state:, event:, effects: [])
          attempt = state[:attempts].fetch(attempt_id) do
            raise ArgumentError, "Unknown attempt: #{attempt_id}"
          end
          unless attempt[:state] == :running
            raise StaleStateError, "attempt #{attempt_id} state is #{attempt[:state].inspect}, expected :running"
          end
          terminal_state = attempt_terminal_state_for(result)
          validate_node_state_for_result!(result, node_state)

          rev_states = state[:node_states][[attempt[:workflow_id], attempt[:revision]]]
          current_node_state = rev_states[attempt[:node_id]]
          unless current_node_state == :running
            raise StaleStateError, "node #{attempt[:node_id]} state is #{current_node_state.inspect}, expected :running"
          end

          reservations = prepare_effect_reservations(state, attempt, effects)

          attempt[:result] = result
          attempt[:state] = terminal_state
          rev_states[attempt[:node_id]] = node_state
          apply_effect_reservations(state, reservations)

          append_event_internal(state, attempt[:workflow_id], event)
        end

        # Implements `Ports::Storage#list_effects_for_node`.
        # @api private
        def list_effects_for_node(state, workflow_id:, revision:, node_id:)
          ensure_effect_state!(state)
          links = state[:node_effect_links].fetch([workflow_id, revision, node_id.to_sym], [])
          records_for_links(state, links)
        end

        # Implements `Ports::Storage#list_effects_for_attempt`.
        # @api private
        def list_effects_for_attempt(state, attempt_id:)
          ensure_effect_state!(state)
          records_for_links(state, state[:attempt_effect_links].fetch(attempt_id, []))
        end

        # Implements `Ports::Storage#claim_ready_effects`.
        # @api private
        def claim_ready_effects(state, limit:, owner_id:, lease_ms:, now_ms:)
          ensure_effect_state!(state)
          validate_nonnegative_integer!(limit, "limit")
          validate_string!(owner_id, "owner_id")
          validate_positive_integer!(lease_ms, "lease_ms")
          validate_integer!(now_ms, "now_ms")

          claimed = []
          state[:effect_order].each do |effect_id|
            break if claimed.size >= limit

            record = state[:effects].fetch(effect_id)
            next unless claimable_effect?(record, now_ms)

            updated = record.with(
              status: :dispatching,
              lease_owner: owner_id,
              lease_until_ms: now_ms + lease_ms,
              updated_at_ms: now_ms
            )
            state[:effects][effect_id] = updated
            claimed << updated
          end
          claimed
        end

        # Implements `Ports::Storage#mark_effect_succeeded`.
        # @api private
        def mark_effect_succeeded(state, effect_id:, owner_id:, result:, external_ref:, now_ms:)
          ensure_effect_state!(state)
          validate_string!(owner_id, "owner_id")
          validate_integer!(now_ms, "now_ms")
          record = fetch_effect!(state, effect_id)
          validate_effect_lease!(record, owner_id: owner_id, now_ms: now_ms)

          updated = record.with(
            status: :succeeded,
            result: result,
            error: nil,
            external_ref: external_ref,
            not_before_ms: nil,
            lease_owner: nil,
            lease_until_ms: nil,
            updated_at_ms: now_ms
          )
          state[:effects][effect_id] = updated
        end

        # Implements `Ports::Storage#mark_effect_failed`.
        # @api private
        def mark_effect_failed(state, effect_id:, owner_id:, error:, retriable:, not_before_ms:, now_ms:)
          ensure_effect_state!(state)
          validate_string!(owner_id, "owner_id")
          validate_integer!(now_ms, "now_ms")
          unless retriable == true || retriable == false
            raise ArgumentError, "retriable must be true or false"
          end
          record = fetch_effect!(state, effect_id)
          validate_effect_lease!(record, owner_id: owner_id, now_ms: now_ms)

          updated = record.with(
            status: retriable ? :failed_retriable : :failed_terminal,
            result: nil,
            error: error,
            external_ref: nil,
            not_before_ms: retriable ? not_before_ms : nil,
            lease_owner: nil,
            lease_until_ms: nil,
            updated_at_ms: now_ms
          )
          state[:effects][effect_id] = updated
        end

        # Implements `Ports::Storage#complete_effect_succeeded`.
        # @api private
        def complete_effect_succeeded(state, effect_id:, owner_id:, result:, external_ref:, now_ms:)
          updated = mark_effect_succeeded(
            state,
            effect_id: effect_id,
            owner_id: owner_id,
            result: result,
            external_ref: external_ref,
            now_ms: now_ms
          )
          {record: updated, released: release_nodes_satisfied_by_effect(state, effect_id: effect_id, now_ms: now_ms)}
        end

        # Implements `Ports::Storage#complete_effect_failed`.
        # @api private
        def complete_effect_failed(state, effect_id:, owner_id:, error:, retriable:, not_before_ms:, now_ms:)
          updated = mark_effect_failed(
            state,
            effect_id: effect_id,
            owner_id: owner_id,
            error: error,
            retriable: retriable,
            not_before_ms: not_before_ms,
            now_ms: now_ms
          )
          released = updated.terminal? ? release_nodes_satisfied_by_effect(state, effect_id: effect_id, now_ms: now_ms) : []
          {record: updated, released: released}
        end

        # Implements `Ports::Storage#release_nodes_satisfied_by_effect`.
        # @api private
        def release_nodes_satisfied_by_effect(state, effect_id:, now_ms:)
          ensure_effect_state!(state)
          validate_integer!(now_ms, "now_ms")
          fetch_effect!(state, effect_id)

          released = []
          state[:attempt_effect_links].each_value do |links|
            links.each do |link|
              next unless link[:effect_id] == effect_id && link[:blocking]

              revision_key = [link[:workflow_id], link[:revision]]
              states_for_rev = state[:node_states].fetch(revision_key, nil)
              next unless states_for_rev && states_for_rev[link[:node_id]] == :waiting
              next unless blocking_effects_terminal?(state, link[:attempt_id])

              states_for_rev[link[:node_id]] = :pending
              released << {
                workflow_id: link[:workflow_id],
                revision: link[:revision],
                node_id: link[:node_id],
                attempt_id: link[:attempt_id],
                released_at_ms: now_ms
              }
            end
          end
          released
        end

        # Implements `Ports::Storage#abort_running_attempts`.
        # @api private
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

        # Implements `Ports::Storage#list_attempts`.
        # @api private
        def list_attempts(state, workflow_id:, revision: nil, node_id: nil)
          state[:attempts_index].fetch(workflow_id, []).map { |aid| state[:attempts][aid] }.select do |attempt|
            (revision.nil? || attempt[:revision] == revision) &&
              (node_id.nil? || attempt[:node_id] == node_id)
          end
        end

        # Implements `Ports::Storage#list_committed_results_for_predecessors`.
        # @api private
        def list_committed_results_for_predecessors(state, workflow_id:, revision:, predecessors:)
          predecessor_ids = predecessors.map(&:to_sym)
          predecessor_set = predecessor_ids.to_set
          best_by_node = {}

          state[:attempts_index].fetch(workflow_id, []).each do |attempt_id|
            attempt = state[:attempts][attempt_id]
            next unless attempt[:revision] == revision
            next unless attempt[:state] == :committed
            next unless predecessor_set.include?(attempt[:node_id])

            current = best_by_node[attempt[:node_id]]
            best_by_node[attempt[:node_id]] = attempt if better_committed_attempt?(attempt, current)
          end

          predecessor_ids.each_with_object({}) do |node_id, results|
            attempt = best_by_node[node_id]
            results[node_id] = attempt[:result] if attempt
          end
        end

        # Implements `Ports::Storage#count_attempts` (excluding `:aborted`).
        # @api private
        def count_attempts(state, workflow_id:, revision:, node_id:)
          count_attempts_internal(state, workflow_id, revision, node_id, exclude: [:aborted])
        end

        # Implements `Ports::Storage#append_event`.
        # @api private
        def append_event(state, workflow_id:, event:)
          append_event_internal(state, workflow_id, event)
        end

        # Internal: stamp seq + push to event log.
        # @api private
        def append_event_internal(state, workflow_id, event)
          state[:seq][workflow_id] ||= 0
          state[:seq][workflow_id] += 1
          stamped = event.with(seq: state[:seq][workflow_id])
          state[:events][workflow_id] ||= []
          state[:events][workflow_id] << stamped
          stamped
        end

        # Implements `Ports::Storage#read_events`.
        # @api private
        def read_events(state, workflow_id:, after_seq: nil, limit: nil)
          events = state[:events].fetch(workflow_id, [])
          events = events.select { |e| e.seq > after_seq } if after_seq
          events = events.first(limit) if limit
          events
        end

        # Implements `Ports::Storage#prepare_workflow_retry` (port extension).
        # Atomic retry boundary: guard workflow state and retry budget, abort
        # prior `:failed` attempts, reset their nodes to `:pending`, increment
        # `workflow_retry_count`, transition the workflow, and optionally
        # append a durable event.
        # @api private
        def prepare_workflow_retry(state, id:, from: :failed, to: :pending, event: nil)
          row = fetch_workflow!(state, id)
          unless row[:state] == from
            raise StaleStateError, "workflow #{id} state is #{row[:state].inspect}, expected #{from.inspect}"
          end

          max_retries = row[:runtime_profile].max_workflow_retries
          if row[:workflow_retry_count] >= max_retries
            raise WorkflowRetryExhaustedError,
              "workflow retries exhausted (#{row[:workflow_retry_count]}/#{max_retries})"
          end

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
          row[:state] = to
          stamped = event ? append_event_internal(state, id, event) : nil

          {id: id, state: to, reset: failed_node_ids, workflow_retry_count: row[:workflow_retry_count], event: stamped}
        end

        # Internal: validate and stage effect reservations without mutating
        # storage. This keeps commit_attempt rollback semantics simple: a
        # fingerprint conflict is raised before attempt/node/event state moves.
        # @api private
        def prepare_effect_reservations(state, attempt, effects)
          ensure_effect_state!(state)
          raise ArgumentError, "effects must be an Array" unless effects.is_a?(Array)

          next_effect_seq = state[:effect_seq]
          pending_by_ref = {}
          new_records = []
          links = []

          effects.each_with_index do |effect, index|
            validate_prepared_effect!(effect, attempt, index)
            existing_id = state[:effects_by_ref][effect.ref]
            record = existing_id ? state[:effects].fetch(existing_id) : pending_by_ref[effect.ref]

            if record
              validate_effect_fingerprint!(record, effect)
              effect_id = record.id
            else
              next_effect_seq += 1
              effect_id = "effect/#{next_effect_seq}"
              record = DAG::Effects::Record.from_prepared(
                id: effect_id,
                prepared_intent: effect,
                status: :reserved,
                updated_at_ms: effect.created_at_ms
              )
              pending_by_ref[effect.ref] = record
              new_records << record
            end

            link = effect_link(effect_id: effect_id, effect: effect)
            links << link unless links.any? { |existing| same_effect_link?(existing, link) }
          end

          {new_records: new_records, links: links}
        end

        # Internal: apply already-validated effect records and links.
        # @api private
        def apply_effect_reservations(state, reservations)
          reservations[:new_records].each do |record|
            state[:effects][record.id] = record
            state[:effects_by_ref][record.ref] = record.id
            state[:effect_order] << record.id
            state[:effect_seq] += 1
          end

          reservations[:links].each do |link|
            attempt_links = (state[:attempt_effect_links][link[:attempt_id]] ||= [])
            next if attempt_links.any? { |existing| same_effect_link?(existing, link) }

            attempt_links << link
            node_key = [link[:workflow_id], link[:revision], link[:node_id]]
            state[:node_effect_links][node_key] ||= []
            state[:node_effect_links][node_key] << link
          end
        end

        # Internal: type/coordinate guard for staged effect intents.
        # @api private
        def validate_prepared_effect!(effect, attempt, index)
          unless effect.is_a?(DAG::Effects::PreparedIntent)
            raise ArgumentError, "effects[#{index}] must be DAG::Effects::PreparedIntent"
          end
          unless effect.workflow_id == attempt[:workflow_id]
            raise ArgumentError, "effects[#{index}].workflow_id does not match attempt"
          end
          unless effect.revision == attempt[:revision]
            raise ArgumentError, "effects[#{index}].revision does not match attempt"
          end
          unless effect.node_id.to_sym == attempt[:node_id].to_sym
            raise ArgumentError, "effects[#{index}].node_id does not match attempt"
          end
          return if effect.attempt_id == attempt[:attempt_id]

          raise ArgumentError, "effects[#{index}].attempt_id does not match attempt"
        end

        # Internal: idempotency guard for semantic effect identity.
        # @api private
        def validate_effect_fingerprint!(record, effect)
          return if record.payload_fingerprint == effect.payload_fingerprint

          raise DAG::Effects::IdempotencyConflictError,
            "effect #{effect.ref} was already reserved with a different payload fingerprint"
        end

        # Internal: attempt-effect link value.
        # @api private
        def effect_link(effect_id:, effect:)
          {
            effect_id: effect_id,
            attempt_id: effect.attempt_id,
            workflow_id: effect.workflow_id,
            revision: effect.revision,
            node_id: effect.node_id.to_sym,
            blocking: effect.blocking
          }
        end

        # Internal: link identity is per attempt/effect pair.
        # @api private
        def same_effect_link?(left, right)
          left[:attempt_id] == right[:attempt_id] && left[:effect_id] == right[:effect_id]
        end

        # Internal: return one projected Record per linked effect. When a node
        # links the same effect across multiple attempts, the most recent link
        # supplies the attempt/blocking coordinates while the durable effect
        # state remains canonical.
        # @api private
        def records_for_links(state, links)
          latest_links_by_effect = {}
          links.each { |link| latest_links_by_effect[link[:effect_id]] = link }
          latest_links_by_effect.values.map do |link|
            project_effect_record(state[:effects].fetch(link[:effect_id]), link)
          end
        end

        # Internal: overlay link coordinates onto the canonical effect record.
        # @api private
        def project_effect_record(record, link)
          record.with(
            workflow_id: link[:workflow_id],
            revision: link[:revision],
            node_id: link[:node_id],
            attempt_id: link[:attempt_id],
            blocking: link[:blocking]
          )
        end

        # Internal: effect lookup.
        # @api private
        def fetch_effect!(state, effect_id)
          state[:effects].fetch(effect_id) do
            raise DAG::Effects::UnknownEffectError, "Unknown effect: #{effect_id}"
          end
        end

        # Internal: dispatch eligibility.
        # @api private
        def claimable_effect?(record, now_ms)
          case record.status
          when :reserved
            true
          when :failed_retriable
            record.not_before_ms.nil? || record.not_before_ms <= now_ms
          when :dispatching
            # Leases are valid through their exact expiry millisecond; only a
            # strictly older lease is claimable by another owner.
            record.lease_until_ms.nil? || record.lease_until_ms < now_ms
          else
            false
          end
        end

        # Internal: lease CAS guard.
        # @api private
        def validate_effect_lease!(record, owner_id:, now_ms:)
          return if record.status == :dispatching &&
            record.lease_owner == owner_id &&
            !record.lease_until_ms.nil? &&
            record.lease_until_ms >= now_ms

          raise DAG::Effects::StaleLeaseError, "stale lease for effect #{record.id}"
        end

        # Internal: whether all blocking effects for an attempt are terminal.
        # @api private
        def blocking_effects_terminal?(state, attempt_id)
          state[:attempt_effect_links].fetch(attempt_id, []).all? do |link|
            !link[:blocking] || state[:effects].fetch(link[:effect_id]).terminal?
          end
        end

        # Internal validations.
        # @api private
        def validate_string!(value, label)
          raise ArgumentError, "#{label} must be String" unless value.is_a?(String)
        end

        # Internal validations.
        # @api private
        def validate_integer!(value, label)
          raise ArgumentError, "#{label} must be Integer" unless value.is_a?(Integer)
        end

        # Internal validations.
        # @api private
        def validate_positive_integer!(value, label)
          raise ArgumentError, "#{label} must be a positive Integer" unless value.is_a?(Integer) && value.positive?
        end

        # Internal validations.
        # @api private
        def validate_nonnegative_integer!(value, label)
          raise ArgumentError, "#{label} must be a non-negative Integer" unless value.is_a?(Integer) && value >= 0
        end

        # Internal validations.
        # @api private
        def validate_workflow_state_for_revision_append!(id, state, allowed_states)
          allowed = allowed_states.map(&:to_sym)
          return if allowed.include?(state)

          if state == :running
            raise DAG::ConcurrentMutationError, "workflow #{id} is running"
          end

          raise DAG::StaleStateError, "workflow #{id} cannot append revision from #{state.inspect}"
        end

        # Internal: canonical committed-attempt ordering.
        # @api private
        def better_committed_attempt?(candidate, current)
          return true if current.nil?

          candidate_number = candidate.fetch(:attempt_number)
          current_number = current.fetch(:attempt_number)
          return true if candidate_number > current_number
          return false unless candidate_number == current_number

          candidate.fetch(:attempt_id).to_s > current.fetch(:attempt_id).to_s
        end

        # Internal helper used by `count_attempts` and friends.
        # @api private
        def count_attempts_internal(state, id, revision, node_id, exclude: [])
          state[:attempts_index].fetch(id, []).count do |aid|
            a = state[:attempts][aid]
            a[:revision] == revision && a[:node_id] == node_id && !exclude.include?(a[:state])
          end
        end

        # Internal: map a step result type to its attempt terminal state.
        # @api private
        def attempt_terminal_state_for(result)
          case result
          when DAG::Success then :committed
          when DAG::Waiting then :waiting
          when DAG::Failure then :failed
          else
            raise ArgumentError, "unexpected attempt result type: #{result.class}"
          end
        end

        # Internal: assert the requested `node_state` is allowed for the result.
        # @api private
        def validate_node_state_for_result!(result, node_state)
          allowed = case result
          when DAG::Success then [:committed]
          when DAG::Waiting then [:waiting]
          when DAG::Failure then %i[failed pending]
          end
          return if allowed.include?(node_state)

          raise ArgumentError, "node_state #{node_state.inspect} is invalid for #{result.class}"
        end
      end
    end
  end
end
