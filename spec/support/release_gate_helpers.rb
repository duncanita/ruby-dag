# frozen_string_literal: true

module ReleaseGateHelpers
  def normalized(path)
    File.read(File.join(self.class::ROOT, path)).split.join(" ")
  end
end
