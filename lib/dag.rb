# frozen_string_literal: true

require_relative "dag/version"

# Core graph
require_relative "dag/errors"
require_relative "dag/edge"
require_relative "dag/result"
require_relative "dag/success"
require_relative "dag/failure"
require_relative "dag/graph"
require_relative "dag/graph/builder"
require_relative "dag/graph/validator"

# Workflow layer
require_relative "dag/workflow/step"
require_relative "dag/workflow/registry"
require_relative "dag/workflow/definition"
require_relative "dag/workflow/steps"
require_relative "dag/workflow/run_callbacks"
require_relative "dag/workflow/parallel"
require_relative "dag/workflow/parallel/strategy"
require_relative "dag/workflow/parallel/sequential"
require_relative "dag/workflow/parallel/threads"
require_relative "dag/workflow/parallel/ractors"
require_relative "dag/workflow/parallel/processes"
require_relative "dag/workflow/runner"
require_relative "dag/workflow/loader"
require_relative "dag/workflow/dumper"
