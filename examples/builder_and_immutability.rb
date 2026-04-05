# frozen_string_literal: true

# Builder pattern, immutability, and copy-on-write editing.
#
# Run: ruby -Ilib examples/builder_and_immutability.rb

require "dag"

# --- Builder produces frozen graphs ---

graph = DAG::Graph::Builder.build do |b|
  b.add_node(:a)
  b.add_node(:b)
  b.add_node(:c)
  b.add_edge(:a, :b)
  b.add_edge(:b, :c)
end

puts "=== Builder ==="
puts "Built: #{graph.inspect}"
puts "Frozen? #{graph.frozen?}"

begin
  graph.add_node(:d)
rescue FrozenError => e
  puts "Mutation blocked: #{e.message}"
end
puts

# --- dup for mutable copies ---

puts "=== Dup (mutable copy) ==="
copy = graph.dup
puts "Copy frozen? #{copy.frozen?}"
copy.add_node(:d)
copy.add_edge(:c, :d)
puts "Copy: #{copy.inspect}"
puts "Original unchanged: #{graph.inspect}"
puts

# --- with_node / with_edge (copy-on-write) ---

puts "=== Copy-on-Write (with_node / with_edge) ==="
extended = graph
  .with_node(:d)
  .with_edge(:c, :d)

puts "Original: #{graph.inspect}"
puts "Extended: #{extended.inspect}"
puts "Extended frozen? #{extended.frozen?}"
puts "Original == Extended? #{graph == extended}"
puts

# --- without_node / without_edge (copy-on-write removal) ---

puts "=== Copy-on-Write (without_node / without_edge) ==="
trimmed = extended.without_node(:d)
puts "without_node(:d): #{trimmed.inspect}"
puts "Frozen? #{trimmed.frozen?}"
puts "Extended unchanged: #{extended.inspect}"

trimmed2 = extended.without_edge(:c, :d)
puts "without_edge(:c, :d): edges=#{trimmed2.edges.size}, still has :d? #{trimmed2.node?(:d)}"
puts

# --- Equality ---

puts "=== Equality ==="
g1 = DAG::Graph::Builder.build do |b|
  b.add_node(:x)
  b.add_node(:y)
  b.add_edge(:x, :y)
end

g2 = DAG::Graph::Builder.build do |b|
  b.add_node(:x)
  b.add_node(:y)
  b.add_edge(:x, :y)
end

puts "Same structure: #{g1 == g2}"
puts "Same hash:      #{g1.hash == g2.hash}"
puts "Can use as Hash key: #{({g1 => "found"}[g2])}"
puts

# --- Validation ---

puts "=== Validation ==="
validated = DAG::Graph::Builder.build do |b|
  b.add_node(:source)
  b.add_node(:sink)
  b.add_node(:orphan)
  b.add_edge(:source, :sink)
end

result = DAG::Graph::Validator.validate(validated) do |v|
  v.rule("must have exactly one root") { |g| g.roots.size == 1 }
end

puts "Valid? #{result.valid?}"
puts "Errors: #{result.errors.inspect}" unless result.valid?
puts

# validate! raises on failure
begin
  DAG::Graph::Validator.validate!(validated)
rescue DAG::ValidationError => e
  puts "Validation failed: #{e.message}"
end
