# frozen_string_literal: true

# A support-triage agent with real application-shaped tools.
#
#   OPENAI_API_KEY=sk-... ruby examples/support_triage.rb
#   script/rb ruby examples/support_triage.rb
#
# The data is local on purpose: Truffle owns the loop and tool dispatch, while
# your app owns the business systems behind each tool.

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "json"
require "truffle"

CUSTOMERS = {
  "dana@example.test" => {
    id: "cus_1042",
    name: "Dana Singh",
    plan: "Pro",
    health: "at_risk",
    lifetime_value: 12_400
  }
}.freeze

ORDERS = {
  "cus_1042" => [
    {
      id: "ord_9001",
      item: "Ergonomic chair",
      total: 349,
      status: "delayed",
      promised_ship_date: "2026-06-28",
      actual_ship_date: "2026-07-02"
    }
  ]
}.freeze

lookup_customer = Truffle.tool("lookup_customer", "Fetch a customer profile by email") do
  param :email, :string, "customer email address", required: true

  run do |email:|
    customer = CUSTOMERS.fetch(email.downcase) { raise "unknown customer: #{email}" }
    JSON.generate(customer)
  end
end

recent_orders = Truffle.tool("recent_orders", "Fetch recent orders for a customer") do
  param :customer_id, :string, "customer id", required: true

  run do |customer_id:|
    JSON.generate(ORDERS.fetch(customer_id, []))
  end
end

create_retention_offer = Truffle.tool("create_retention_offer",
                                      "Create a retention offer for an at-risk customer") do
  param :customer_id, :string, "customer id", required: true
  param :percent, :integer, "discount percentage", required: true
  param :reason, :string, "short reason", required: true

  run do |customer_id:, percent:, reason:|
    JSON.generate(
      customer_id: customer_id,
      code: "SAVE#{percent}",
      percent: percent,
      reason: reason,
      expires_at: "2026-07-14"
    )
  end
end

agent = Truffle.agent(
  provider: :openai,
  model: ENV.fetch("TRUFFLE_MODEL", "gpt-4o-mini"),
  system_prompt: <<~PROMPT,
    You triage ecommerce support tickets.
    Always look up the customer and their recent orders before deciding.
    If a Pro customer is at risk and their order is delayed, create one
    retention offer before answering. Be concise and practical.
  PROMPT
  tools: [lookup_customer, recent_orders, create_retention_offer],
  max_turns: 8
)

agent.on(:tool_call) do |event|
  args = event[:call].arguments.map { |key, value| "#{key}=#{value.inspect}" }.join(", ")
  puts "  -> #{event[:call].name}(#{args})"
end

agent.on(:tool_result) do |event|
  puts "  <- #{event[:call].name}: #{event[:result]}"
end

ticket = ARGV.join(" ")
if ticket.empty?
  ticket = "Dana at dana@example.test says the chair she ordered is late, " \
           "paid customers should not wait this long, and she may cancel."
end

puts "Ticket: #{ticket}"
puts "-" * 72
answer = agent.run(ticket)
puts "-" * 72
puts answer
