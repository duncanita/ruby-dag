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
