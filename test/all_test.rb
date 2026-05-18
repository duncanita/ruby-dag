# frozen_string_literal: true

Dir[File.expand_path("../spec/**/*_test.rb", __dir__)].sort.each do |path|
  require path
end
