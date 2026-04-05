# frozen_string_literal: true

# Extension: LLM step type for DAG workflows.
#
#   require "dag/ext/llm"
#
# Registers the :llm step type and adds :llm to Loader's valid types.

require_relative "../workflow/steps/llm"

DAG::Workflow::Steps::REGISTRY[:llm] = DAG::Workflow::Steps::LLM
DAG::Workflow::Loader::YAML_TYPES << :llm
DAG::Workflow::Loader::ALL_TYPES << :llm
