# frozen_string_literal: true

require_relative "../test_helper"

class ManyWorkflowsSingleProcessTest < Minitest::Test
  def test_100_workflows_complete_in_one_process
    storage = DAG::Adapters::Memory::Storage.new
    runner = build_runner(storage: storage)
    ids = Array.new(100) do
      create_workflow(storage, simple_definition, initial_context: {n: rand(1_000)})
    end

    ids.each { |id| runner.call(id) }

    ids.each do |id|
      assert_equal :completed, storage.load_workflow(id: id)[:state]
    end
  end
end
