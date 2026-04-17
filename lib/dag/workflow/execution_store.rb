# frozen_string_literal: true

require "digest"
require "fileutils"

module DAG
  module Workflow
    module ExecutionStore
      class FileStore
        def initialize(dir:)
          @dir = File.expand_path(dir)
          FileUtils.mkdir_p(@dir)
        end

        def begin_run(workflow_id:, definition_fingerprint:, node_paths:)
          run = load_run(workflow_id)
          if run
            run[:node_paths] |= normalized_node_paths(node_paths)
          else
            run = {
              workflow_id: workflow_id,
              definition_fingerprint: definition_fingerprint,
              node_paths: normalized_node_paths(node_paths),
              workflow_status: nil,
              waiting_nodes: [],
              paused: false,
              trace: [],
              nodes: {}
            }
          end
          write_run(run)
          deep_copy(run)
        end

        def load_run(workflow_id)
          path = run_path(workflow_id)
          return nil unless File.exist?(path)

          Marshal.load(File.binread(path))
        end

        def paused?(workflow_id)
          load_run(workflow_id)&.fetch(:paused, false) || false
        end

        def next_output_version(workflow_id:, node_path:)
          node = fetch_node(load_run(workflow_id), node_path)
          outputs = node ? Array(node[:outputs]) : []
          (outputs.map { |entry| entry[:version] }.max || 0) + 1
        end

        def load_node(workflow_id:, node_path:)
          node = fetch_node(load_run(workflow_id), node_path)
          node ? deep_copy(node) : nil
        end

        def set_node_state(workflow_id:, node_path:, state:, reason: nil, metadata: {})
          run = ensure_run(workflow_id)
          node = ensure_node(run, node_path)
          node[:state] = state
          node[:reason] = reason
          node[:metadata] = deep_copy(metadata)
          write_run(run)
          nil
        end

        def append_trace(workflow_id:, entry:)
          run = ensure_run(workflow_id)
          run[:trace] << entry
          write_run(run)
          nil
        end

        def save_output(workflow_id:, node_path:, version:, result:, reusable:, superseded:, saved_at: Time.now.utc)
          run = ensure_run(workflow_id)
          node = ensure_node(run, node_path)
          node[:outputs] ||= []
          node[:outputs] << {
            version: version,
            result: result,
            reusable: reusable,
            superseded: superseded,
            saved_at: saved_at
          }
          write_run(run)
          nil
        end

        def load_output(workflow_id:, node_path:, version: :latest)
          node = fetch_node(ensure_run(workflow_id), node_path)
          return nil unless node

          outputs = Array(node[:outputs])
          active_outputs = outputs.reject { |entry| entry[:superseded] }
          case version
          when :latest
            # standard:disable Style/ReverseFind -- Array#rfind is unavailable on Ruby 3.2, which this gem still tests against.
            output = active_outputs.reverse_each.find { |entry| entry[:reusable] }
            # standard:enable Style/ReverseFind
            output ? deep_copy(output) : nil
          when :all
            deep_copy(outputs.sort_by { |entry| entry[:version] })
          else
            output = outputs.find { |entry| entry[:version] == version }
            output ? deep_copy(output) : nil
          end
        end

        def mark_stale(workflow_id:, node_paths:, cause:)
          mark_nodes(
            workflow_id: workflow_id,
            node_paths: node_paths,
            state: :stale,
            cause_key: :stale_cause,
            cause: cause
          )
        end

        def mark_obsolete(workflow_id:, node_paths:, cause:)
          mark_nodes(
            workflow_id: workflow_id,
            node_paths: node_paths,
            state: :obsolete,
            cause_key: :obsolete_cause,
            cause: cause
          )
        end

        def set_workflow_status(workflow_id:, status:, waiting_nodes: [])
          run = ensure_run(workflow_id)
          run[:workflow_status] = status
          run[:waiting_nodes] = normalized_node_paths(waiting_nodes)
          write_run(run)
          nil
        end

        def set_pause_flag(workflow_id:, paused:)
          run = ensure_run(workflow_id)
          run[:paused] = paused
          write_run(run)
          nil
        end

        def clear_run(workflow_id:)
          path = run_path(workflow_id)
          File.delete(path) if File.exist?(path)
          nil
        end

        private

        def mark_nodes(workflow_id:, node_paths:, state:, cause_key:, cause:)
          run = ensure_run(workflow_id)
          Array(node_paths).each do |node_path|
            node = ensure_node(run, node_path)
            node[:state] = state
            node[cause_key] = deep_copy(cause)
            Array(node[:outputs]).each do |output|
              output[:superseded] = true if output[:reusable]
            end
          end
          write_run(run)
          nil
        end

        def ensure_run(workflow_id)
          load_run(workflow_id) || raise(ArgumentError, "unknown workflow_id: #{workflow_id.inspect}")
        end

        def ensure_node(run, node_path)
          key = normalize_node_path(node_path)
          run[:nodes][key] ||= {node_path: key, outputs: []}
        end

        def fetch_node(run, node_path)
          return nil unless run

          run[:nodes][normalize_node_path(node_path)]
        end

        def normalize_node_path(node_path)
          Array(node_path).map(&:to_sym).freeze
        end

        def normalized_node_paths(node_paths)
          Array(node_paths).map { |node_path| normalize_node_path(node_path) }
        end

        def run_path(workflow_id)
          File.join(@dir, "#{Digest::SHA256.hexdigest(workflow_id.to_s)}.store")
        end

        def write_run(run)
          path = run_path(run.fetch(:workflow_id))
          tmp_path = "#{path}.tmp-#{Process.pid}-#{Thread.current.object_id}"
          File.binwrite(tmp_path, Marshal.dump(run))
          File.rename(tmp_path, path)
        ensure
          File.delete(tmp_path) if tmp_path && File.exist?(tmp_path)
        end

        def deep_copy(value)
          Marshal.load(Marshal.dump(value))
        end
      end

      class MemoryStore
        def initialize
          @runs = {}
        end

        def begin_run(workflow_id:, definition_fingerprint:, node_paths:)
          run = @runs[workflow_id]
          if run
            run[:node_paths] |= normalized_node_paths(node_paths)
          else
            run = {
              workflow_id: workflow_id,
              definition_fingerprint: definition_fingerprint,
              node_paths: normalized_node_paths(node_paths),
              workflow_status: nil,
              waiting_nodes: [],
              paused: false,
              trace: [],
              nodes: {}
            }
            @runs[workflow_id] = run
          end
          deep_copy(run)
        end

        def load_run(workflow_id)
          run = @runs[workflow_id]
          run ? deep_copy(run) : nil
        end

        def paused?(workflow_id)
          @runs[workflow_id]&.fetch(:paused, false) || false
        end

        def next_output_version(workflow_id:, node_path:)
          node = fetch_node(@runs[workflow_id], node_path)
          outputs = node ? Array(node[:outputs]) : []
          (outputs.map { |entry| entry[:version] }.max || 0) + 1
        end

        def load_node(workflow_id:, node_path:)
          node = fetch_node(@runs[workflow_id], node_path)
          node ? deep_copy(node) : nil
        end

        def set_node_state(workflow_id:, node_path:, state:, reason: nil, metadata: {})
          node = ensure_node(workflow_id, node_path)
          node[:state] = state
          node[:reason] = reason
          node[:metadata] = deep_copy(metadata)
          nil
        end

        def append_trace(workflow_id:, entry:)
          run = ensure_run(workflow_id)
          run[:trace] << entry
          nil
        end

        def save_output(workflow_id:, node_path:, version:, result:, reusable:, superseded:, saved_at: Time.now.utc)
          node = ensure_node(workflow_id, node_path)
          node[:outputs] ||= []
          node[:outputs] << {
            version: version,
            result: result,
            reusable: reusable,
            superseded: superseded,
            saved_at: saved_at
          }
          nil
        end

        def load_output(workflow_id:, node_path:, version: :latest)
          node = fetch_node(ensure_run(workflow_id), node_path)
          return nil unless node

          outputs = Array(node[:outputs])
          active_outputs = outputs.reject { |entry| entry[:superseded] }
          case version
          when :latest
            # standard:disable Style/ReverseFind -- Array#rfind is unavailable on Ruby 3.2, which this gem still tests against.
            output = active_outputs.reverse_each.find { |entry| entry[:reusable] }
            # standard:enable Style/ReverseFind
            output ? deep_copy(output) : nil
          when :all
            deep_copy(outputs.sort_by { |entry| entry[:version] })
          else
            output = outputs.find { |entry| entry[:version] == version }
            output ? deep_copy(output) : nil
          end
        end

        def mark_stale(workflow_id:, node_paths:, cause:)
          mark_nodes(
            workflow_id: workflow_id,
            node_paths: node_paths,
            state: :stale,
            cause_key: :stale_cause,
            cause: cause
          )
        end

        def mark_obsolete(workflow_id:, node_paths:, cause:)
          mark_nodes(
            workflow_id: workflow_id,
            node_paths: node_paths,
            state: :obsolete,
            cause_key: :obsolete_cause,
            cause: cause
          )
        end

        def set_workflow_status(workflow_id:, status:, waiting_nodes: [])
          run = ensure_run(workflow_id)
          run[:workflow_status] = status
          run[:waiting_nodes] = normalized_node_paths(waiting_nodes)
          nil
        end

        def set_pause_flag(workflow_id:, paused:)
          ensure_run(workflow_id)[:paused] = paused
          nil
        end

        def clear_run(workflow_id:)
          @runs.delete(workflow_id)
          nil
        end

        private

        def mark_nodes(workflow_id:, node_paths:, state:, cause_key:, cause:)
          Array(node_paths).each do |node_path|
            node = ensure_node(workflow_id, node_path)
            node[:state] = state
            node[cause_key] = deep_copy(cause)
            Array(node[:outputs]).each do |output|
              output[:superseded] = true if output[:reusable]
            end
          end
          nil
        end

        def ensure_run(workflow_id)
          @runs.fetch(workflow_id) do
            raise ArgumentError, "unknown workflow_id: #{workflow_id.inspect}"
          end
        end

        def ensure_node(workflow_id, node_path)
          run = ensure_run(workflow_id)
          key = normalize_node_path(node_path)
          run[:nodes][key] ||= {node_path: key, outputs: []}
        end

        def fetch_node(run, node_path)
          return nil unless run

          run[:nodes][normalize_node_path(node_path)]
        end

        def normalize_node_path(node_path)
          Array(node_path).map(&:to_sym).freeze
        end

        def normalized_node_paths(node_paths)
          Array(node_paths).map { |node_path| normalize_node_path(node_path) }
        end

        def deep_copy(value)
          case value
          when Hash
            value.each_with_object({}) do |(key, nested), copy|
              copy[deep_copy(key)] = deep_copy(nested)
            end
          when Array
            value.map { |nested| deep_copy(nested) }
          when Success
            Success.new(value: deep_copy(value.value))
          when Failure
            Failure.new(error: deep_copy(value.error))
          when TraceEntry
            TraceEntry.new(
              name: deep_copy(value.name),
              layer: deep_copy(value.layer),
              started_at: deep_copy(value.started_at),
              finished_at: deep_copy(value.finished_at),
              duration_ms: deep_copy(value.duration_ms),
              status: deep_copy(value.status),
              input_keys: deep_copy(value.input_keys),
              attempt: deep_copy(value.attempt),
              retried: deep_copy(value.retried)
            )
          else
            value
          end
        end
      end
    end
  end
end
