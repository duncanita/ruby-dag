# frozen_string_literal: true

# Graph basics: building, querying, and analyzing a DAG.
#
# Run: ruby -Ilib examples/graph_basics.rb

require "dag"

# --- Building a graph with the fluent API ---

graph = DAG::Graph.new
  .add_node(:fetch)
  .add_node(:parse)
  .add_node(:validate)
  .add_node(:transform)
  .add_node(:store)
  .add_edge(:fetch, :parse)
  .add_edge(:parse, :validate)
  .add_edge(:parse, :transform)
  .add_edge(:validate, :store)
  .add_edge(:transform, :store)

puts "=== Graph Overview ==="
puts graph.inspect
puts "Size: #{graph.size}"
puts

# --- Topological algorithms ---

puts "=== Topological Ordering ==="
puts "Layers (parallelizable): #{graph.topological_layers.inspect}"
puts "Flat sort:               #{graph.topological_sort.inspect}"
puts

# --- Neighbor and transitive queries ---

puts "=== Queries ==="
puts "Roots:                   #{graph.roots.inspect}"
puts "Leaves:                  #{graph.leaves.inspect}"
puts "Successors of :parse:    #{graph.successors(:parse).inspect}"
puts "Predecessors of :store:  #{graph.predecessors(:store).inspect}"
puts "Ancestors of :store:     #{graph.ancestors(:store).inspect}"
puts "Descendants of :fetch:   #{graph.descendants(:fetch).inspect}"
puts

# --- Path detection ---

puts "=== Path Detection ==="
puts "fetch -> store?  #{graph.path?(:fetch, :store)}"
puts "store -> fetch?  #{graph.path?(:store, :fetch)}"
puts "ghost -> ghost?  #{graph.path?(:ghost, :ghost)}"
puts

# --- Degree queries ---

puts "=== Degree ==="
graph.each_node do |node|
  puts "  #{node}: indegree=#{graph.indegree(node)} outdegree=#{graph.outdegree(node)}"
end
puts

# --- Subgraph extraction ---

puts "=== Subgraph ==="
sub = graph.subgraph([:parse, :validate, :transform, :store])
puts "Subgraph (without :fetch): #{sub.inspect}"
puts "Subgraph layers: #{sub.topological_layers.inspect}"
puts

# --- Membership checks ---

puts "=== Membership ==="
puts "node?(:fetch):    #{graph.node?(:fetch)}"
puts "node?(:missing):  #{graph.node?(:missing)}"
puts "edge?(:fetch, :parse):  #{graph.edge?(:fetch, :parse)}"
puts "edge?(:parse, :fetch):  #{graph.edge?(:parse, :fetch)}"
puts

# --- Edge iteration ---

puts "=== Edge Iteration ==="
graph.each_edge do |edge|
  puts "  #{edge.from} → #{edge.to}"
end
puts

# --- Mutable removal ---

puts "=== Mutable Removal ==="
mutable = graph.dup
puts "Before: #{mutable.size} nodes, #{mutable.edges.size} edges"

mutable.remove_edge(:validate, :store)
puts "After remove_edge(:validate, :store): #{mutable.edges.size} edges"

mutable.remove_node(:transform)
puts "After remove_node(:transform): #{mutable.size} nodes, #{mutable.edges.size} edges"
puts "Layers: #{mutable.topological_layers.inspect}"
puts

# --- Serialization ---

puts "=== Serialization ==="
pp graph.to_h
puts

# --- Cycle detection ---

puts "=== Cycle Detection ==="
begin
  graph.dup.add_edge(:store, :fetch)
rescue DAG::CycleError => e
  puts "Caught: #{e.message}"
end

# --- Empty graph ---

puts
puts "=== Empty Graph ==="
empty = DAG::Graph.new
puts "Empty? #{empty.empty?}"
puts "Size:  #{empty.size}"
