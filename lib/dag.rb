# frozen_string_literal: true

require_relative "dag/version"

# Core graph
require_relative "dag/errors"
require_relative "dag/immutability"
require_relative "dag/edge"
require_relative "dag/result"
require_relative "dag/effects"
require_relative "dag/success"
require_relative "dag/failure"
require_relative "dag/types"
require_relative "dag/graph"
require_relative "dag/graph/builder"
require_relative "dag/graph/validator"

# Boundary ports
require_relative "dag/ports/storage"
require_relative "dag/ports/event_bus"
require_relative "dag/ports/fingerprint"
require_relative "dag/ports/clock"
require_relative "dag/ports/id_generator"
require_relative "dag/ports/serializer"

# R1 kernel
require_relative "dag/execution_context"
require_relative "dag/step_protocol"
require_relative "dag/step/base"
require_relative "dag/step_type_registry"
require_relative "dag/builtin_steps/noop"
require_relative "dag/builtin_steps/passthrough"
require_relative "dag/workflow/definition"
require_relative "dag/workflow/definition/builder"
require_relative "dag/plan_result"
require_relative "dag/apply_result"
require_relative "dag/definition_editor"
require_relative "dag/mutation_service"
require_relative "dag/runner"

# Default adapters
require_relative "dag/adapters/stdlib/clock"
require_relative "dag/adapters/stdlib/id_generator"
require_relative "dag/adapters/stdlib/fingerprint"
require_relative "dag/adapters/stdlib/serializer"
require_relative "dag/adapters/null/event_bus"
require_relative "dag/adapters/memory/event_bus"
require_relative "dag/adapters/memory/storage_state"
require_relative "dag/adapters/memory/storage"
require_relative "dag/adapters/memory/crashable_storage"

# Convenience factory for examples, tests, and quick-start scripts
require_relative "dag/toolkit"
