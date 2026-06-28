# frozen_string_literal: true

# A tiny end-to-end demo: a calculator agent with two tools.
#
#   OPENAI_API_KEY=sk-... ruby examples/calculator.rb
#   # or, on a host with no local Ruby:
#   script/rb ruby examples/calculator.rb
#
# The agent decides when to call `add` / `multiply`, Truffle runs them, feeds the
# results back, and the model produces the final answer. Every step is printed
# through the event API so you can watch the loop work.

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "truffle"

add = Truffle::Tool.define("add", "Add two integers") do
  param :a, :integer, "first addend", required: true
  param :b, :integer, "second addend", required: true
  run { |a:, b:| a + b }
end

multiply = Truffle::Tool.define("multiply", "Multiply two integers") do
  param :a, :integer, "first factor", required: true
  param :b, :integer, "second factor", required: true
  run { |a:, b:| a * b }
end

agent = Truffle.agent(
  provider: :openai,
  model: ENV.fetch("TRUFFLE_MODEL", "gpt-4o-mini"),
  system_prompt: "You are a precise calculator. Use the tools for every " \
                 "arithmetic step. Show the final result clearly.",
  tools: [add, multiply]
)

agent.on(:tool_call) do |e|
  puts "  -> calling #{e[:call].name}(#{e[:call].arguments.map do |k, v|
    "#{k}=#{v}"
  end.join(", ")})"
end
agent.on(:tool_result) { |e| puts "  <- #{e[:call].name} returned #{e[:result]}" }

question = ARGV.join(" ")
question = "What is (12 + 8) multiplied by 7?" if question.empty?

puts "Q: #{question}"
puts "-" * 60
answer = agent.run(question)
puts "-" * 60
puts "A: #{answer}"
