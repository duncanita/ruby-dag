# frozen_string_literal: true

require_relative "../test_helper"

# Roadmap v3.4 §9.1: no AI/LLM vocabulary in the kernel. The kernel is a
# deterministic workflow runtime; consumer-domain words must not leak into
# `lib/` source, comments, or docs. This is the executable grep gate the
# roadmap's mitigation column calls for.
class R0KernelAiTermsTest < Minitest::Test
  FORBIDDEN_TERMS = /\b(llm|openai|anthropic|gpt|chatbot|prompt|copilot)\b/i

  def test_lib_sources_contain_no_ai_terms
    root = File.expand_path("../..", __dir__)
    offenders = Dir[File.join(root, "lib", "**", "*.rb")].filter_map do |path|
      relative = path.delete_prefix("#{root}/")
      matches = File.readlines(path).each_with_index.filter_map do |line, index|
        "#{relative}:#{index + 1}" if line.match?(FORBIDDEN_TERMS)
      end
      matches unless matches.empty?
    end.flatten

    assert_empty offenders, "AI/LLM terms are banned in the kernel (Roadmap §9.1)"
  end
end
