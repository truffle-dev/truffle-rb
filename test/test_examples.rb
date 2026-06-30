# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"

class TestExamples < Minitest::Test
  EXAMPLES = Dir[File.expand_path("../examples/*.rb", __dir__)].freeze

  def test_examples_parse_as_ruby
    EXAMPLES.each do |path|
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-c", path)

      assert_predicate status, :success?, "#{path} did not parse:\n#{stdout}\n#{stderr}"
    end
  end
end
