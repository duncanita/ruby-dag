# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/storage_contract"

class MemoryStorageContractTest < Minitest::Test
  include StorageContract::WorkflowLifecycle
  include StorageContract::RevisionCAS
  include StorageContract::AttemptAtomicity
  include StorageContract::EventLog

  def build_contract_storage
    DAG::Adapters::Memory::Storage.new
  end
end
