# Pith

A small, provider-agnostic **agent harness for Ruby**. Pith gives you the loop
that turns a language model into an agent: it sends a prompt, lets the model
ask for tools, runs those tools, feeds the results back, and repeats until the
model answers. No framework, no service, no heavy dependency tree. Plain Ruby
and the standard library.

```ruby
require "pith"

weather = Pith.tool("get_weather", "Look up the weather for a city") do
  param :city, :string, "city name", required: true
  run { |city:| "It is 22C and sunny in #{city}." }
end

agent = Pith.agent(
  provider: :openai,
  model: "gpt-4o-mini",
  system_prompt: "You are a concise assistant. Use tools when they help.",
  tools: [weather]
)

puts agent.run("What's the weather in Lisbon?")
# => "It's 22C and sunny in Lisbon right now."
```

The model decided to call `get_weather(city: "Lisbon")`, Pith ran your Ruby
block, handed the result back, and the model wrote the final answer. That whole
round trip is the agent loop, and it is the thing Pith exists to give you.

![Pith test suite and a live three-tool agent run](docs/screenshot-tests.png)

*The full suite (unit tests plus one live OpenAI round-trip) passing, and the
calculator example chaining three real tool calls to reach 240.*

## Why Pith

Ruby already has an excellent LLM client layer in
[ruby_llm](https://github.com/crmne/ruby_llm): one consistent API across many
providers. What Ruby has been missing is a tiny, readable **agent runtime** on
top of that seam, the part that owns the turn loop, the tool dispatch, the
message history, and the events a UI hangs off.

Pith is a Ruby port of the agent-core ideas in
[pi](https://github.com/earendil-works/pi). It keeps the runtime and drops
everything else, so you can read the whole loop in one sitting (`lib/pith/agent.rb`)
and understand exactly what your agent does.

- **Provider-agnostic.** The agent talks to a single `chat` seam. A provider is
  any object that answers `chat(messages:, tools:, model:)`. An OpenAI provider
  ships in the box; a `ruby_llm` adapter is on the roadmap, which unlocks every
  provider ruby_llm already supports.
- **Tools are plain blocks.** Define a tool with a name, a description, typed
  params, and a Ruby block. Pith generates the JSON Schema the model needs and
  symbolizes the model's arguments back into keyword args for you.
- **Observable.** Subscribe to `agent_start`, `tool_call`, `tool_result`,
  `agent_end`, and more. Build a TUI, a log stream, or a web view without the
  harness knowing how it is rendered.
- **Dependency-free core.** The OpenAI provider uses `Net::HTTP` and the JSON
  in the standard library. Nothing to vendor, nothing to audit but the code you
  see.

## Install

```ruby
# Gemfile
gem "pith"
```

```sh
bundle install
```

Or from a checkout:

```sh
gem build pith.gemspec
gem install ./pith-0.1.0.gem
```

Pith targets Ruby >= 3.1.

## Quick start

Set your key and run the bundled calculator example, which shows the model
chaining several tool calls:

```sh
export OPENAI_API_KEY=sk-...
ruby examples/calculator.rb "What is (12 + 8) multiplied by 7, then add 100?"
```

```
Q: What is (12 + 8) multiplied by 7, then add 100?
------------------------------------------------------------
  -> calling add(a=12, b=8)
  <- add returned 20
  -> calling multiply(a=20, b=7)
  <- multiply returned 140
  -> calling add(a=140, b=100)
  <- add returned 240
------------------------------------------------------------
A: The final result is 240.
```

## Core concepts

### Tools

```ruby
add = Pith.tool("add", "Add two integers") do
  param :a, :integer, "first addend", required: true
  param :b, :integer, "second addend", required: true
  run { |a:, b:| a + b }
end
```

- `param name, type, description, required:` declares an input. Types map to
  JSON Schema (`:string`, `:integer`, `:number`, `:boolean`, ...).
- `run { |a:, b:| ... }` is your handler. The model emits string keys; Pith
  symbolizes them into keyword args. Return any value; it is stringified before
  it goes back to the model.
- Raising inside a handler does not crash the loop. The error is caught and fed
  back to the model as the tool result, so it can recover or apologize.

### Agents

```ruby
agent = Pith.agent(
  provider: :openai,
  model: "gpt-4o-mini",
  system_prompt: "You are a precise calculator.",
  tools: [add],
  max_turns: 12
)

answer = agent.run("What is 2 + 3?")
agent.reset   # clears history, keeps the system prompt and tools
```

`run` drives the loop to completion and returns the final assistant text.
`max_turns` guards against a model that never settles; exceeding it raises
`Pith::Error`.

### Events

```ruby
agent.on(:tool_call)   { |e| puts "-> #{e[:call].name}(#{e[:call].arguments})" }
agent.on(:tool_result) { |e| puts "<- #{e[:result]}" }
agent.on               { |type, payload| logger.debug(type => payload) }  # every event
```

Events fire in order: `agent_start`, then per turn `turn_start`, `message`,
`tool_call`/`tool_result` (one pair per tool the model invokes), `turn_end`,
and finally `agent_end`.

### Providers

A provider is anything that implements:

```ruby
def chat(messages:, tools:, model: nil, **options)
  # -> Pith::Response
end
```

The bundled `Pith::Providers::OpenAI` talks to the Chat Completions API over
`Net::HTTP`. To target another backend today, subclass
`Pith::Providers::Base` and implement `chat`. The roadmap adds a first-class
`ruby_llm` adapter so you get every provider it supports for free.

## Testing

```sh
rake test
```

The default suite is hermetic and offline: it drives the agent loop with a stub
provider, so you can run it anywhere without a key. One additional test
(`test/test_openai_integration.rb`) performs a real OpenAI round trip and is
**skipped unless `OPENAI_API_KEY` is set**. With a key present it verifies the
full path: prompt -> model requests a tool -> Pith runs it -> model answers
with the tool's result.

No local Ruby? The repo ships `script/rb`, a thin wrapper that runs any command
inside a `ruby:3.3-slim` container, so `script/rb rake test` works on a host
with only Docker.

## Project layout

```
lib/pith.rb                  # top-level API: Pith.agent, Pith.tool, Pith.provider
lib/pith/agent.rb            # the agent loop (the heart of the port)
lib/pith/tool.rb             # tool DSL + JSON Schema generation
lib/pith/toolbox.rb          # a named collection of tools
lib/pith/message.rb          # message + tool-call value objects
lib/pith/response.rb         # a provider's reply
lib/pith/providers/base.rb   # the provider seam
lib/pith/providers/openai.rb # OpenAI Chat Completions provider
examples/calculator.rb       # runnable multi-tool demo
test/                        # minitest suite (offline + one live test)
```

## Credits

Pith is a Ruby port of the agent-core runtime in
[pi](https://github.com/earendil-works/pi) by Mario Zechner (MIT). The
provider-agnostic ambition and the end-to-end ergonomics are inspired by
[ruby_llm](https://github.com/crmne/ruby_llm) by Carmine Paolino (MIT). Thanks
to both projects.

## License

MIT. See [LICENSE](LICENSE).
