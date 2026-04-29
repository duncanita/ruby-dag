# frozen_string_literal: true

module DAG
  class Graph
    # Validates a Graph for structural issues beyond basic acyclicity (cycles
    # are already rejected at edge-insertion time, so the validator does not
    # check for them). Collects all errors rather than failing on the first.
    #
    #   report = DAG::Graph::Validator.validate(graph) do |v|
    #     v.rule("must have a single root") { |g| g.roots.size == 1 }
    #   end
    #
    #   report.valid?  # => true/false
    #   report.errors  # => ["Node c is disconnected", ...]
    #
    # Default built-in rules: `:no_isolated` (multi-node graphs must not
    # contain any node with neither predecessors nor successors). Override the
    # defaults with the `defaults:` keyword:
    #
    #   DAG::Graph::Validator.validate(graph, defaults: [])           # no rules
    #   DAG::Graph::Validator.validate(graph, defaults: [:no_isolated]) # explicit

    Report = Data.define(:errors) do
      def initialize(errors:)
        super(errors: errors.freeze)
      end

      def valid? = errors.empty?
    end

    # Validates a Graph for structural issues beyond basic acyclicity.
    # @api public
    class Validator
      # Names of all rule slots the validator knows about.
      AVAILABLE_RULES = %i[no_isolated].freeze
      # Rule slots active when `defaults:` is not overridden.
      DEFAULT_RULES = %i[no_isolated].freeze

      # @param graph [Graph]
      # @param defaults [Array<Symbol>] rules from {AVAILABLE_RULES}
      # @yieldparam validator [Validator] used to register custom `rule`s
      # @return [Report]
      def self.validate(graph, defaults: DEFAULT_RULES, &block)
        validator = new(graph, defaults: defaults)
        block&.call(validator)
        validator.run
      end

      def self.validate!(graph, defaults: DEFAULT_RULES, &block)
        report = validate(graph, defaults: defaults, &block)
        raise ValidationError, report.errors unless report.valid?
        graph
      end

      def initialize(graph, defaults: DEFAULT_RULES)
        @graph = graph
        @defaults = defaults
        @custom_rules = []
      end

      # Register a custom rule. The block receives the graph and must
      # return a truthy value when the rule is satisfied.
      # @param message [String] error message used when the rule fails
      # @return [void]
      def rule(message, &block)
        @custom_rules << [message, block]
      end

      # Apply default + custom rules and return a {Report}.
      # @return [Report]
      def run
        errors = []
        check_isolated_nodes(errors) if @defaults.include?(:no_isolated)
        check_custom_rules(errors)
        Report.new(errors: errors)
      end

      private

      # A node is "isolated" only in a multi-node graph where it has no edges.
      # A single-node graph is trivially valid: the lone node is both root and
      # leaf, and an empty graph has nothing to check.
      def check_isolated_nodes(errors)
        return if @graph.size <= 1

        @graph.each_node do |node|
          next unless @graph.indegree(node).zero? && @graph.outdegree(node).zero?

          errors << "Node #{node} is isolated (no edges)"
        end
      end

      def check_custom_rules(errors)
        @custom_rules.each do |message, check|
          errors << message unless check.call(@graph)
        end
      end
    end
  end
end
