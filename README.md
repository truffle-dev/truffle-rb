<h1 align="center">Truffle</h1>

<p align="center">
  <strong>A dependency-free Ruby agent harness, built from scratch.</strong><br>
  Tool calls, providers, sessions, compaction, streaming, and events in plain Ruby.
</p>

<p align="center">
  <a href="https://github.com/truffle-dev/truffle-rb/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/truffle-dev/truffle-rb/actions/workflows/ci.yml/badge.svg"></a>
  <a href="https://codecov.io/gh/truffle-dev/truffle-rb"><img alt="Coverage" src="https://codecov.io/gh/truffle-dev/truffle-rb/graph/badge.svg?branch=main"></a>
  <a href="https://rubygems.org/gems/truffle"><img alt="Gem Version" src="https://img.shields.io/gem/v/truffle"></a>
  <a href="truffle.gemspec"><img alt="Ruby >= 3.1" src="https://img.shields.io/badge/ruby-%3E%3D%203.1-CC342D"></a>
  <a href="https://github.com/rubocop/rubocop"><img alt="Code style: RuboCop" src="https://img.shields.io/badge/code_style-rubocop-brightgreen.svg"></a>
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue.svg"></a>
</p>

<p align="center">
  Truffle gives Ruby applications the loop that turns a language model into a
  tool-using agent: send a prompt, let the model ask for tools, run those tools,
  feed the results back, and repeat until the model answers. It is a faithful
  Ruby port of <a href="https://github.com/earendil-works/pi">pi</a>. No
  framework, no hosted service, no runtime gem dependencies.
</p>

```ruby
require "truffle"

lookup_customer = Truffle.tool(
  "lookup_customer",
  "Fetch a customer"
) do
  param :email,
        :string,
        "customer email",
        required: true

  run do |email:|
    customer = Customers.find_by!(
      email: email
    )
    customer.to_json
  end
end

agent = Truffle.agent(
  provider: :openai,
  model: "gpt-5.4-mini",
  system_prompt: "Triage tickets. Use tools first.",
  tools: [lookup_customer]
)

ticket = "dana@example.test says her order is late."
puts agent.run(ticket)
```

## Why Truffle

Ruby has strong libraries for web apps, jobs, and data. It also needs a small
agent runtime that can live inside those apps without hiding the moving parts.
Truffle owns the model loop, tool dispatch, message history, session state, and
events. Your app owns the tools and business rules.

- **Provider-agnostic.** OpenAI, Anthropic, and Google Gemini providers ship in
  the box, each hand-written against the wire API. You can also pass any object
  that implements `chat(messages:, tools:, model:)`.
- **Plain Ruby tools.** A tool is a named block with typed params. Truffle
  generates the JSON Schema for the model and calls your block with keyword args.
- **Observable loop.** Subscribe to tool calls, tool results, turn boundaries,
  retries, compaction, and final answers to build logs, UIs, or audit trails.
- **Session-aware.** Agents can persist and reload conversation state, branch,
  label, compact old turns, and recover from context-window overflows. Sessions
  record the active provider and model, default to a JSONL file, and talk to
  storage through a small seam, so a host can back them with a database or
  anything else (see `examples/custom_session_store.rb`).
- **No runtime dependencies.** The core uses Ruby's standard library.

## Install

```ruby
# Gemfile
gem "truffle"
```

```sh
bundle install
```

Truffle targets Ruby 3.1 and newer.

Installing the gem also adds a `truffle` command. Today it answers
`truffle --version`, `truffle --help`, `truffle --list-models`, `truffle init`,
one-shot `truffle --print` runs, and a line-oriented interactive REPL. Use
`truffle --mode json "..."` when an app wants newline-delimited agent events
instead of only the final text. Text `@file` arguments are included in the first
prompt, and supported image `@file` arguments attach to that first model turn.
On a terminal, assistant text streams to stdout while thinking, tool activity,
retry notices, and compaction status go to stderr. Pass `--no-stream` for
buffered output. Ctrl-C cancels the active request; in the REPL it returns to
the prompt for the next turn.
Interactive runs create a session by default; pass `--no-session` for an
ephemeral loop. `truffle --continue` loads the most recent session for the
current project. `truffle --resume` opens a numbered picker, `--session
<path|id>` loads a session file or unique session id across projects, and
`--fork <path|id>` branches an existing session into the current project. Use
`--session-id <id>` to choose the session id and `--name <name>` to set its
display name. Automatic image resizing, RPC mode, all-session browsing, and a
richer TUI are still in progress.

Run `truffle init` in an app repo to create `.truffle/` project state and an
`AGENTS.md` project memory file. It is safe to rerun; existing files are left
unchanged, and migrations run before missing paths are scaffolded so older
`.truffle/settings.json` files, legacy `commands/` directories, and root-level
session files are brought forward safely.

`.truffle/settings.json` can set the runtime defaults a project wants:
`defaultProvider`, `defaultModel`, `compaction`, and `retry`. `Truffle.agent`
uses those values only when the caller leaves the matching option unset, so app
code can still override them per agent.

Sessions have a default home. `Agent#dump` and `Session.create` without a `dir:`
write under `~/.truffle/agent/sessions/--<encoded-cwd>--/`, a per-project
directory keyed by the working directory, so you get session history without
choosing a path (pass `dir:` to override, or set `TRUFFLE_AGENT_DIR`).

To resume, read that directory back. `Session.most_recent(cwd: Dir.pwd)` returns
the path of the most recently active session for the project (nil when there is
none), and `Session.list(cwd: Dir.pwd)` returns every session there, newest
first:

```ruby
path = Truffle::Session.most_recent(cwd: Dir.pwd)
agent = Truffle::Agent.load(path, provider: provider) if path
```

## A Real Example

The support-triage example shows the shape Truffle is built for: a Ruby app
exposes business tools, the model chooses the right calls, and Truffle keeps the
loop observable.

```sh
export OPENAI_API_KEY=sk-...
ruby examples/support_triage.rb
```

It defines three tools:

- `lookup_customer(email:)`
- `recent_orders(customer_id:)`
- `create_retention_offer(customer_id:, percent:, reason:)`

The run prints each tool call and result before the final answer:

```text
Ticket: Dana at dana@example.test says the chair she ordered is late...
------------------------------------------------------------------------
  -> lookup_customer(email="dana@example.test")
  <- lookup_customer: {"id":"cus_1042","name":"Dana Singh",...}
  -> recent_orders(customer_id="cus_1042")
  <- recent_orders: [{"id":"ord_9001","item":"Ergonomic chair",...}]
  -> create_retention_offer(customer_id="cus_1042", percent=15, ...)
  <- create_retention_offer: {"customer_id":"cus_1042","code":"SAVE15",...}
------------------------------------------------------------------------
...
```

The full file is [examples/support_triage.rb](examples/support_triage.rb). The
smaller calculator demo in [examples/calculator.rb](examples/calculator.rb)
remains useful when you want to see multiple arithmetic tools chained together.

## Core API

### Tools

```ruby
add = Truffle.tool("add", "Add two integers") do
  param :a, :integer, "first addend", required: true
  param :b, :integer, "second addend", required: true
  run { |a:, b:| a + b }
end
```

Tool handlers may return strings, numbers, arrays, or hashes. Non-string values
are serialized to JSON before they are sent back to the model. If a handler
raises, Truffle feeds the error back as the tool result so the model can recover.

### Agents

```ruby
agent = Truffle.agent(
  provider: :openai,
  model: "gpt-5.4-mini",
  system_prompt: "You are precise. Use tools for arithmetic.",
  tools: [add],
  max_turns: 12
)

answer = agent.run("What is 23 + 19?")
```

`run` drives the loop until the model returns a final answer. When a model asks
for several tools in one turn, Truffle runs independent calls in parallel by
default and appends results back to history in source order. Use
`tool_execution: :sequential` when a batch must run one call at a time.

For local image input, build image blocks and pass them with the prompt:

```ruby
image = Truffle::Content::Image.from_file("screenshot.png")
answer = agent.run("What changed?", images: [image].compact)
```

For structured final data, pass a schema through the agent harness instead of
calling a provider directly. `run_structured` requests native structured output
from the provider, parses the final JSON, validates it against the schema, and
returns the parsed Ruby value:

```ruby
schema = Truffle::Schema.build do
  param :category, :string, required: true
  param :priority, :string, enum: %w[low medium high], required: true
end

data = agent.run_structured("Classify this ticket: #{ticket}", schema: schema)
# => {"category"=>"billing", "priority"=>"high"}
```

`run` and `run_stream` accept the same `schema:`, `schema_name:`, and `strict:`
options when an app wants the raw final text. The full provider response is kept
on `agent.last_response`.

### Events

```ruby
agent.on(:tool_call)   { |event| puts "-> #{event[:call].name}" }
agent.on(:tool_result) { |event| puts "<- #{event[:result]}" }
agent.on               { |type, payload| logger.debug(type => payload) }
```

Events are ordered and include turn starts, assistant messages, tool calls, tool
results, retries, compaction, and the final `agent_end`.

For token-level UI updates, use the streaming loop. It yields the same
`Truffle::StreamEvent` objects that providers emit and still returns the final
text when the multi-turn run is complete:

```ruby
answer = agent.run_stream("Draft a reply") do |event|
  case event.type
  when :text_delta
    broadcast(event.delta)
  when :toolcall_end
    audit(event.tool_call)
  end
end
```

The transport is application code: send the events to SSE, ActionCable,
WebSocket, logs, or a terminal renderer.

### Providers And Models

```ruby
Truffle.models
Truffle.model("gpt-5.5")
Truffle.model("claude-sonnet-4-6")
```

The model catalog records provider, model id, context window, max output,
modalities, reasoning support, and pricing. `Truffle.agent(model: "...")` can
infer the provider for catalog models; pass `provider:` explicitly for custom or
OpenAI-compatible endpoints. The resolved capability record is available as
`agent.model_spec`, while `agent.model` remains the provider's wire id. The
examples above use `gpt-5.4-mini` for a fast, low-cost default; reach for a
flagship such as `gpt-5.5`, `claude-opus-4-8`, or `claude-sonnet-4-6` when a
task needs deeper reasoning.

Register an OpenAI-compatible endpoint in-process when an app already has the
connection details and does not need an extension file:

```ruby
Truffle.register_provider(
  "local",
  api: :openai_completions,
  base_url: "http://localhost:11434/v1",
  api_key: "$LOCAL_LLM_API_KEY",
  models: [
    { id: "llama3", input: ["text"] }
  ]
)

agent = Truffle.agent(model: "local/llama3")
```

`Truffle.providers` returns a small runtime registry facade for embedding apps
and extension hosts:

```ruby
providers = Truffle.providers
providers.provider_names
providers.resolve_model("local/llama3")
providers.set_provider("local", api: :openai_completions, base_url: "...", model: "llama3")
providers.delete_provider("local")
```

Passing `extensions:` makes the facade read loaded extension registrations too:

```ruby
providers = Truffle.providers(extensions: loaded_extensions)
providers.get_provider("local")
providers.get_model("local", "llama3")
```

The facade can inspect non-OpenAI provider metadata, but request execution is
still implemented for built-in providers and OpenAI-compatible chat endpoints.
OAuth flows, dynamic remote model refresh, non-chat APIs, and pi's
`streamSimple` transport remain future provider-runtime slices.

Declare `input: ["text"]` for a text-only registered model. Truffle then keeps
image blocks in session history but replaces them with an omission marker in
requests to that model. Registrations that omit `input` remain conservative and
send images unchanged.

### Extensions

Ruby extension files can register tools, slash commands, event handlers, and
OpenAI-compatible providers. A command handler can accept a second argument for
the live runtime context:

```ruby
truffle.register_command("compact", description: "Compact this session") do |_args, ctx|
  ctx.compact ? "Session compacted" : "Nothing to compact"
end

truffle.register_command("name", description: "Set the session name") do |args, ctx|
  "Named #{ctx.set_session_name(args)}"
end
```

The context exposes the active agent, session, provider, model id, model
metadata, usage, system prompt, cwd, abort signal, command metadata, model
catalog helpers, provider registry access, session display-name helpers, and
manual compaction. Event and command handlers can call `ctx.abort("reason")`
to request cooperative cancellation of the active run. UI-heavy pi actions such
as session switching, tree
navigation, overlays, and RPC remain future runtime slices.

```ruby
truffle.register_command("providers", description: "List runtime providers") do |_args, ctx|
  ctx.model_registry.provider_names.join("\n")
end
```

## Testing

For local Ruby:

```sh
bundle install
rake test
bundle exec rubocop
```

The one-command path is:

```sh
script/check
```

The default suite is hermetic and offline. Live provider tests are skipped unless
their keys are present:

```sh
cp .env.local.example .env.local
# fill OPENAI_API_KEY, ANTHROPIC_API_KEY, and/or GEMINI_API_KEY
script/check
```

`script/rb` runs any command inside a Ruby 3.3 container and loads `.env.local`
without printing secrets:

```sh
script/rb rake test
script/rb ruby examples/support_triage.rb
script/rb ruby -Ilib exe/truffle --no-session
```

Interactive `script/rb` invocations preserve the terminal, so the last command
uses the same streaming and Ctrl-C path as the installed executable.

Coverage is opt-in:

```sh
COVERAGE=true script/rb rake test
```

## Documentation

- [ROADMAP.md](ROADMAP.md): what has shipped and what is next.
- [CONTRIBUTING.md](CONTRIBUTING.md): local setup, tests, and release notes.
- [CHANGELOG.md](CHANGELOG.md): release-facing changes.
- [AGENTS.md](AGENTS.md): conventions for automated contributors.

## Credits

Truffle is a from-scratch Ruby port of
[pi](https://github.com/earendil-works/pi) by Mario Zechner (MIT). pi is the
blueprint; the Ruby implementation is written from the ground up.

## License

MIT. See [LICENSE](LICENSE).
