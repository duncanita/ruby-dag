# frozen_string_literal: true

# Extension: LLM step type for DAG workflows.
#
#   require "dag/ext/llm"
#
# Registers the :llm step type via the plugin registry.

require_relative "../workflow/steps/llm"

DAG::Workflow::Steps.register(:llm, DAG::Workflow::Steps::LLM, yaml_safe: true)
