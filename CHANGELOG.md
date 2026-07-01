# Changelog

All notable changes to Truffle are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the project aims to follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed
- Built-in providers now run completed string-shaped tool-call arguments through
  `Truffle::JsonRepair.parse` before falling back to `_raw`, so malformed string
  literals from a model can still dispatch as normal parsed arguments.
- Built-in provider serializers now sanitize outbound system, user, assistant,
  thinking, and tool-result text before building JSON request bodies, matching
  pi's provider boundary behavior and avoiding invalid UTF-8 surrogate errors.
- `Agent.load` now reattaches the loaded session to the resumed agent. New turns
  appended after a resume are persisted to the same session file instead of only
  living in memory, and session-backed runs write an updated usage checkpoint at
  agent end so later reloads resume cost accounting too.

### Added
- `Truffle::PartialJson.parse` and `.parse_streaming` complete a truncated JSON
  document mid-stream, so a model's in-flight tool-call arguments become a usable
  object before the closing token arrives. `parse` is a from-scratch port of the
  `partial-json` package (0.1.7): a recursive-descent parser gated by an `Allow`
  bitmask that returns as much structure as it can. `parse_streaming` layers the
  `JsonRepair` complete-document path over it and always returns an object,
  porting pi's `parseStreamingJson`. Faithfulness was checked against the
  reference package across ~600 differential inputs. Zero runtime dependencies.
- `Truffle::JsonRepair.repair` and `.parse` recover malformed JSON string
  literals in model output. `repair` escapes raw control characters and doubles
  a backslash before an invalid escape, both only inside string literals;
  `parse` retries with the repaired text only when the first parse fails and the
  repair changed the input, otherwise it re-raises the original error. Port of
  the dependency-free half of pi's json-parse.ts.
- `Truffle::UnicodeSanitizer.sanitize_surrogates` strips lone Unicode surrogate
  byte sequences from text so it can be serialized into a provider request body
  without JSON encoding errors. Valid characters, including astral emoji and the
  adjacent U+D000-U+D7FF range, are left untouched; a clean string is returned
  unchanged.
- CLI-built agents now use the shared system prompt builder for fresh and
  resumed runs. `--system-prompt`, repeated `--append-system-prompt`, enabled
  builtin tool descriptions, and AGENTS/CLAUDE context files now flow into the
  agent prompt unless `--no-context-files` is passed.
- Fresh interactive CLI runs now honor `--session-id`: an existing project
  session with that exact id is reopened, while a missing id creates the new
  session under that id. Invalid ids and conflicting resume flags fail before
  any provider call.
- `truffle --fork <path|id>` now creates a new project session from an existing
  session file or local session reference, records the source file as the
  parent session, and resumes the REPL from the fork. `--session-id` can name the
  fork target when the id is not already in use.
- `truffle --resume` now shows a numbered, line-oriented picker for current
  project sessions before building the agent. Selecting a session reuses the
  existing resume path; blank input or `q` exits without a provider call.
- `truffle --continue` now loads the most recent session for the current project
  in both print mode and the interactive REPL. `--session <path|id>` resolves a
  specific session file or unique project session reference. The interactive
  picker remains a later richer-TUI slice.
- Fresh interactive CLI runs now create a project session by default, recording
  the model and enabled builtin tool names before the first turn. `--no-session`
  keeps the REPL ephemeral, and fresh print-mode runs stay sessionless.
- A first interactive REPL for the `truffle` binary. A bare `truffle` starts a
  line-oriented loop over one agent, processes any initial CLI messages, reads
  turns until EOF or `/exit`, and renders assistant text with the same final-turn
  rules as print mode. Provider/model and builtin-tool flags use the shared CLI
  agent builder; pi's full TUI and RPC runtime remain later work.
- `Truffle::SessionCwd` checks that a session's recorded working directory still
  exists before a resume. `missing_issue(session_cwd:, fallback_cwd:,
  session_file:)` returns an issue when the directory is gone (nil when there is
  no session file, no recorded cwd, or the directory is present),
  `format_error` / `format_prompt` build the user-facing strings, and
  `assert_exists` raises `SessionCwd::MissingError` carrying the issue. Port of
  pi's core/session-cwd.ts.
- `Truffle::Migrations` renames legacy project and global `commands/`
  directories to `prompts/` when no `prompts/` directory exists, matching pi's
  `migrateCommandsToPrompts`. `truffle init` now runs migrations before
  scaffolding missing paths so this safe rename can happen.
- `Truffle::Migrations.run_project` adds the first project-local migration
  runner. `truffle init` now runs it before scaffolding, stamping existing
  unversioned `.truffle/settings.json` objects with the current version while
  preserving other keys. Malformed or newer settings are left untouched with a
  warning.
- `Truffle::Migrations.run_agent` moves legacy root-level session JSONL files
  into their per-project session directory based on the session header `cwd`,
  matching pi's startup migration. `truffle init` runs it with the project
  migration pass; malformed files and existing targets are skipped.
- Session discovery for resume. `Session.most_recent(cwd:)` returns the path of
  the most recently active session for a project (nil when there is none), and
  `Session.list(cwd:)` returns summaries newest-first; both default their
  directory to the per-project location and can be pointed at any `dir:`.
  `Session.read_header(path)` reads and validates just a session file's header
  without loading the conversation. Corrupt files are skipped and a missing
  directory lists nothing, matching pi's findMostRecentSession.
- `Truffle::Settings.load_project` reads `.truffle/settings.json` into a
  read-only runtime settings object. It maps pi-style `defaultProvider` /
  `defaultModel`, `compaction`, and `retry` values onto the options Truffle
  already supports, and `Truffle.agent` uses those project defaults only when
  the caller leaves the matching option unset.
- Sessions now have a default per-project directory. `Config.default_session_dir`
  puts a session's JSONL under `~/.truffle/agent/sessions/--<encoded-cwd>--/`,
  encoding the working directory the way pi does (leading separator stripped,
  `/`, `\`, and `:` folded to `-`) so two projects never share a directory.
  `Session.create` and `Agent#dump` default `dir:` to it, so a caller gets
  per-project session history without naming a directory; passing `dir:`
  explicitly still works.
- `truffle init` creates project-local Truffle state without overwriting existing
  files: `.truffle/` with `settings.json`, `prompts/`, `extensions/`, `skills/`,
  and `sessions/`, plus an `AGENTS.md` project memory file when one is absent.
- `Agent#run_stream` drives the normal multi-turn agent loop through provider
  streaming, yielding normalized `Truffle::StreamEvent` objects for token-level
  UI updates while keeping `Agent#run` unchanged. Streamed tool calls still run
  tools and continue the loop, aborts end with `stop_reason: :aborted`, and the
  final return value remains the assistant text.
- A pluggable session store seam lets a host back conversations with its own
  persistence (a database, Redis, anything) without Truffle taking a dependency.
  `Session` talks to storage through a small interface (`#read`, `#write`,
  `#append`, `#exists?`, `#path`); `Session::FileStore` is the default conformer
  and keeps the JSONL format, the interrupted-final-line tolerance, and the
  v1/v2 migration as its own concern. `Session.start(store:, cwd:, ...)` and
  `Session.open(store)` are the store-generic entry points, while
  `Session.create(dir:)`, `Session.load(path)`, `session.file`, and
  `Agent.load(path)` are unchanged and now build a file store internally. The
  `#append` contract holds the store consistent across its block, so the #32
  flock/leaf-refresh semantics stay in the file store. See
  `examples/custom_session_store.rb` for an illustrative in-memory store.
- `Agent.load` can rebuild a provider from the provider/model recorded in a
  session when the provider is available through extensions or the in-process
  registry. Passing `provider:` still wins, but extension-backed sessions no
  longer need a caller to manually reconstruct the same provider instance.
- `script/refresh-models` regenerates `lib/truffle/models.rb` from
  `models.dev/api.json` as an explicit maintenance step. The generator uses
  `Net::HTTP`, filters to provider-backed text-output models Truffle can route,
  emits all four `Model` cost keys, skips duplicate dated snapshots when the
  base id is present, and stays out of runtime loading.
- `Truffle::Schema` is an immutable JSON-Schema value object for structured
  output, built by a block DSL that mirrors `Tool::Builder`'s `param`. It
  describes the shape a model should return: an object root with
  `properties`/`required`, scalar fields, nested objects, and arrays with an
  `items` schema. `#to_h` emits the provider-neutral hash (symbol structural
  keys, string property names, matching `Tool#parameters`), and `.from_h` is its
  inverse, folding string or symbol keys back to the canonical form so a JSON
  round-trip survives equality. Values are deeply frozen and usable as hash keys.
  This is the foundation for the `schema:` provider seam and a structured
  `Response#parsed` accessor.
- A `schema:` option on `#chat` and `#chat_stream` requests native structured
  output from each provider. OpenAI wires it into `response_format.json_schema`
  (with `schema_name` and opt-in `strict`), Anthropic into `output_config.format`
  (stripping the tool-only `strict` key), and Gemini into
  `generationConfig.responseJsonSchema` plus `responseMimeType`. The option takes
  a `Truffle::Schema` or a plain JSON-Schema hash. OpenAI drops the field for a
  non-native base URL (Ollama, vLLM, ...) that may not support it.
- `Response#parsed` lazily parses the final assistant text as JSON without
  changing `#text`. `Truffle::Schema#valid?` and `#errors` provide advisory
  validation for the JSON-Schema subset Truffle emits: type, enum, required
  object properties, nested properties, and array items.
- `Truffle.register_provider` and `Truffle.unregister_provider` add a
  process-local registry for OpenAI-compatible providers, using the same config
  shape as extension `truffle.register_provider` without requiring an extension
  file. `Truffle.provider` and `Truffle.agent(model: "provider/model")` consult
  the registry before falling back to built-in providers.
- `Truffle::Mime` detects the image MIME type of a binary buffer or a file from
  its leading bytes, a port of pi's coding-agent `utils/mime.ts`. It recognizes
  JPEG, PNG, GIF, WEBP, and BMP, and returns nil for a lossless JPEG or an
  animated PNG, which a model cannot take. The checks read raw bytes, so no image
  library is added. `Truffle::Content::Image.from_file` and `.from_bytes` expose
  the local bytes-to-image-block conversion used by `@file` image arguments.
- The `truffle` binary now acts on `--print`/`-p`: it drives a single-shot
  agent run and writes either the final assistant turn (`--mode text`) or one
  JSON object per agent event (`--mode json`) to stdout, faithful ports of pi's
  `runPrintMode` text and JSON branches. Piped stdin and the first message join
  into the initial prompt; any further messages are sent in order after it. An
  error or aborted final text turn prints its message to stderr with exit 1, and
  an unresolvable provider/model fails the same way. The builtin tools are wired
  by default and narrowed by `--no-tools`, `--tools`, and `--exclude-tools`.
  `--mode json` also works without `--print`, matching pi's print-mode shortcut.
  RPC output mode now reports that it is not implemented instead of falling
  through to print or interactive mode. Text `@file` arguments are spliced into
  the initial prompt after piped stdin and before the first message, wrapped in
  pi's `<file name="...">` block. Supported image `@file` arguments now attach
  to the first model turn as image content blocks, with an empty file marker in
  the text prompt for filename context. Sessions, extensions, skills, automatic
  image resizing, and the interactive REPL remain later slices.

### Fixed
- `Truffle.agent` now treats the default project settings load like pi's
  tolerant settings path: a malformed `.truffle/settings.json` no longer blocks
  explicit provider/model construction. `Truffle::Settings.load_project` remains
  strict for callers that want validation, and `try_load_project` exposes the
  captured load errors.
- The `find` tool now clamps a non-positive `limit` to one result instead of
  returning an empty body with a nonsensical `0 results limit reached` notice.
- Tool calls with missing required params or undeclared keyword params now return
  model-readable tool results such as `missing keyword: path` or
  `unknown keyword: cwd` before the handler runs, instead of surfacing Ruby's
  keyword `ArgumentError`. Handlers that raise their own `ArgumentError` still
  use the existing tool-error path.
- The `bash` tool now fails a command killed by a signal (an OOM kill, an
  external `SIGKILL`) instead of returning its partial output as success. Such a
  command has no exit code, so the exit-code guard alone let it pass; the signal
  is now surfaced with the shell's `128 + signal` convention. pi cannot see this
  because its `waitForChildProcess` keeps only Node's exit-code argument and
  drops the signal; Ruby's `Process::Status` carries it.
- Extension loading now collects syntax-errored Ruby extension files as per-file
  load errors instead of letting `SyntaxError` abort the whole load.
- The `read` tool now handles empty files as one empty line, matching pi's
  JavaScript split behavior instead of raising "offset beyond end of file."
- OpenAI reasoning-model calls now send `max_completion_tokens` instead of the
  deprecated `max_tokens` field on the native OpenAI endpoint, while
  OpenAI-compatible extension endpoints keep `max_tokens`.
- Hitting `Agent#max_turns` now ends the run through `agent_end` with
  `stop_reason: :error` and a clear error message instead of raising out of the
  loop.
- Session appends no longer reparse older message content just to decide whether
  the first assistant message has been seen, so sessions containing
  forward-compatible content blocks can still accept new entries.
- `Session.load` now raises on malformed JSONL before the final line instead of
  silently dropping the corrupt entry and shortening the resumed conversation.
  A truncated final line is still tolerated as an interrupted append.
- Legacy session migration now writes through a same-directory temp file, keeps
  a `.bak` copy of the original session, and renames the completed rewrite into
  place instead of truncating the only copy in place.
- Appending to an already-flushed session now locks and refreshes the on-disk
  entry chain first, so two resumed `Session` instances append to the latest leaf
  instead of forking and hiding one writer's turn.
- `Agent#dump` / `Agent.load` now preserve accumulated token usage and cost, so
  a resumed agent continues accounting from the saved session instead of
  restarting totals at zero.
- The built-in `write`, `edit`, and `bash` tools now run sequentially when they
  appear in a multi-tool turn, preventing parallel file mutations from silently
  overwriting each other.

### Added
- Print-mode text renderer. `Truffle::CLI.render_print_text(response, out:, err:)`
  ports the text branch of pi's `runPrintMode` (`modes/print-mode.ts`): given the
  final assistant `Response` of a single-shot run, an error or aborted stop reason
  writes `error_message || "Request <reason>"` to stderr and returns exit 1, while
  any other stop reason writes each text content block on its own line to stdout
  (thinking and tool-call blocks skipped) and returns 0. A nil response prints
  nothing and exits 0. Pure over streams, so it renders offline without a
  provider; the `--print` dispatch that drives the agent and calls it is a later
  slice.
- `truffle --list-models [search]` now prints the built-in model catalog as an
  offline table sorted by provider and model. The output mirrors pi's
  provider/model/context/max-output/thinking/images columns, supports fuzzy
  search against provider, id, and name, and exits zero without requiring API
  keys or network access.
- System prompt assembly. `Truffle::SystemPrompt.build` ports pi's
  `core/system-prompt.ts` `buildSystemPrompt`: the string an agent runs under,
  in either the custom-prompt branch or the default coding-agent branch. The
  tools list shows a tool only when the caller supplies a non-empty one-line
  snippet (and reads `(none)` otherwise); the guidelines are deduplicated in
  insertion order (the bash-only `ls`/`rg`/`find` heuristic first, then caller
  guidelines trimmed with blanks dropped, then the two always-on lines); the
  optional `<project_context>` block wraps each pre-loaded file; and the
  read-tool-gated `<available_skills>` block is appended through
  `Skills.format_for_prompt`. The default prompt names Truffle and points at the
  gem's bundled README and `examples/`, now shipped in the gem. The current date
  is injectable so the assembly stays deterministic in tests; it defaults to the
  wall clock. Produces the system-prompt string the agent already accepts;
  wiring the builder into the agent constructor is a later slice.
- Project context-file loader. `Truffle::ContextFiles.load` ports pi's
  `core/resource-loader.ts` `loadProjectContextFiles`: it discovers the
  `AGENTS.md` / `CLAUDE.md` instruction files that feed `SystemPrompt.build`'s
  `<project_context>` block. The global agent-directory file comes first, then the
  chain from the filesystem root down to the working directory so the nearest file
  lands last; within a directory the first existing candidate wins (`AGENTS.md`
  over `CLAUDE.md`), a file reachable by more than one route appears once, and an
  unreadable candidate warns and falls through to the next name. The warning sink
  is injectable so tests stay quiet.
- CLI argument parser. `Truffle::CLI.parse_args` ports pi's `cli/args.ts`
  `parseArgs`: a pure function from an argv array to an `Args` struct of parsed
  flags, messages, file arguments, captured unknown flags, and diagnostics, with no
  side effects. It carries pi's quirks faithfully: a value-taking flag at the end of
  argv with no value falls through to the unknown-flag branch rather than erroring,
  `--name` with no value records an error diagnostic, `--thinking` warns on an
  unrecognized level while `--mode` silently ignores one, `--print` captures a
  following message unless it is a flag or `@file` (a `---`-prefixed token still
  counts as a message), `--models` keeps blank entries after trimming while
  `--tools` drops them, and an unknown `--flag` claims the next non-flag argument as
  its value. The REPL, help text, and acting on the parsed flags are later slices.
- CLI help and version text. `Truffle::CLI.help_text` and `Truffle::CLI.version_text`
  port pi's `cli/args.ts` `printHelp`: pure string builders for the `--help` screen
  and the `--version` line, so the binary stays a thin caller and the text is
  testable offline. Section headers bold on a terminal (pass `color: true`) and stay
  plain in pipes and tests. The options block lists exactly the flags `parse_args`
  recognizes, with a test that parses every documented flag so the help and the
  parser cannot drift apart. The environment variables and built-in tool names
  describe this harness's real surface (the three providers it ships and the six
  built-in tools), not pi's full provider matrix.
- `truffle` executable. The gem now ships a `truffle` binary backed by
  `Truffle::CLI.run`, the Ruby counterpart of the top of pi's `main.ts` dispatch:
  it parses argv, prints the parser's diagnostics (`Error:` / `Warning:`), and
  acts on the terminal flags the harness supports today. `--version` prints the
  version line and `--help` prints the help screen (colored only on a terminal);
  any error diagnostic exits non-zero before either runs, and `--version` wins
  over `--help` when both are given. `run` takes injectable output streams and
  returns an exit status, so the whole dispatch is testable offline. The
  interactive REPL, `--export`, and `--list-models` remain later slices, so a run
  with no actionable flag reports that interactive mode is not implemented yet.
- `Truffle::Config` defines the local config layout for command prompts:
  `~/.truffle/agent` (or `TRUFFLE_AGENT_DIR`) for user-scoped state and
  `.truffle` for project-scoped state. `PromptTemplates.load_all` now loads prompt
  templates in pi's order: user prompt directory, project prompt directory, then
  explicit prompt paths. Project prompts can be skipped with `include_project:`
  when an embedding app wants to require trust before reading local instructions.
- Extensions. `Truffle::EventBus` ports pi's channel-based event bus, the
  publish/subscribe seam pi hands to extensions as `pi.events` so independently
  loaded extensions communicate without direct references. `emit(channel, data)`
  fans a payload out to every handler on a channel, `on(channel, handler)`
  subscribes and returns an unsubscribe closure, and `clear` drops every
  subscription. A handler that raises is isolated: the error is reported through a
  logger (defaulting to `$stderr`, like pi's `console.error`) and neither stops the
  other handlers nor propagates back into `emit`, and `emit` dispatches over a
  snapshot of the channel so subscribing or unsubscribing mid-handler is safe. The
  bus is guarded by a `Monitor` for cross-thread use. This is the first slice of
  the extensions plugin seam (item 18); the loader and runner build on it later.
- Extension discovery. `Truffle::Extensions` ports the pure filesystem layer of
  pi's `core/extensions/loader.ts`: the seam that finds extension entry points on
  disk before anything is loaded. `extension_file?` recognizes a `.rb` module (pi's
  `.ts`/`.js` analog), `read_manifest` reads a `package.json` `pi` field, and
  `resolve_entries` resolves a directory to its manifest-declared extensions or an
  `index.rb`. `discover_in_dir` walks a directory one level deep, taking each direct
  `.rb` file and each subdirectory's resolved entries, following symlinks the way pi
  reads a symbolic-link dirent and staying error-tolerant so a single broken package
  cannot abort discovery. Loading and runtime binding build on this discovery
  layer.
- Extension loading foundation. `Extensions.load_file` evaluates a Ruby extension
  entry with a `truffle` API object, mirroring pi's factory-call shape while
  staying Ruby-native. Extensions can register tools, slash commands, event
  handlers, and provider configs as data; `load_files` returns loaded extensions
  plus per-file errors so one broken extension does not stop the rest. Binding
  those registrations into an agent/session remains a later item-18 slice.
- Default extension directories. `Extensions.load_all` now loads extension
  entries in pi's order: project `.truffle/extensions`, user
  `agent_dir/extensions`, then explicit paths. Explicit directories resolve as a
  package/index first and otherwise discover direct entries inside the directory,
  with expanded-path deduplication before loading.
- Extension tools and commands now bind into agents. `Agent` and `Truffle.agent`
  accept loaded extensions from `Extensions.load_file`, `load_files`, or
  `load_all`; extension tools join the toolbox, app-supplied tools override a
  same-name extension tool, extension slash commands join the command registry,
  duplicate command names keep the existing `:1`, `:2` suffixing, and
  `Agent.load` can rebind session-required tools from extensions.
- Extension event handlers now bind into agents. Handlers registered with
  `truffle.on(...)` observe the agent events Truffle already emits, in extension
  load order and registration order. A raising handler is captured on
  `agent.extension_errors` and does not stop later handlers or the agent run.
- Extension provider registrations now bind into provider construction.
  `Truffle.provider` and `Truffle.agent` can use loaded
  `truffle.register_provider` configs for OpenAI Chat Completions-compatible
  endpoints, honoring registered `base_url` / `baseUrl`, `api_key` / `apiKey`,
  default `model`, and `models`. Later registrations for the same provider
  override defined values, `LoadResult` runtime unregisters are respected, and
  registered model references can infer the provider without mutating the global
  catalog.
- Extension-registered OpenAI-compatible providers now carry custom request
  headers into both chat and streaming requests. Provider-level `headers` values
  support the same literal and `$ENV` / `${ENV}` interpolation used for api keys;
  `auth_header` / `authHeader` controls whether Truffle generates the bearer
  `Authorization` header; and caller-supplied `headers:` override registered
  header defaults per key.
- Extension-registered OpenAI-compatible provider models now carry their own
  request headers into chat and streaming requests. Model-level `headers` use the
  same literal and `$ENV` / `${ENV}` interpolation as provider headers, apply to
  the actual request model, and merge after provider defaults but before generated
  bearer auth.
- Agents now observe later OpenAI-compatible extension provider registrations
  before the next provider turn. An extension event handler or slash-command
  handler can call `truffle.register_provider` after the agent is constructed,
  and the following request uses the updated endpoint, key, model, and headers.
- Agents now observe later `truffle.unregister_provider` calls before the next
  provider turn. Built-in provider names restore the built-in provider with
  caller overrides; extension-only provider names fail clearly instead of
  silently reusing a stale endpoint.
- `Truffle::PromptTemplates` now ports pi's command prompt-template layer for
  explicit paths: markdown files load by basename, description comes from
  frontmatter or the first body line, `argument-hint` is preserved, direct
  directory scans are deterministic, and `/name args` expands through the
  argument parser. The parser handles bash-style quoted arguments and
  single-pass substitution for `$1`, `$@`, `$ARGUMENTS`, `${N:-default}`,
  `${@:N}`, and `${@:N:L}` placeholders. Default prompt directories remain a
  later item-17 slice.
- `Truffle::SlashCommands::Registry` now handles slash command lookup and
  dispatch. Prompt commands expand into user text before the provider sees a
  turn; handler commands run locally without consuming a provider response; and
  duplicate command names receive `:1`, `:2`, ... invocation suffixes like pi's
  extension commands. `Agent` accepts `prompt_templates:` and `slash_commands:`
  so callers can opt into this behavior without changing existing agents.
- Skills. `Truffle::Frontmatter` parses the optional YAML frontmatter at the head
  of a markdown file and returns it with the trimmed body. `Truffle::Skills` loads
  one skill file into a `Skill` plus diagnostics: the name comes from the
  frontmatter and falls back to the parent directory, a blank description drops the
  skill, and an over-long name/description or invalid name characters warn but
  still load. `Skills.load_dir` discovers skills under a directory: a directory
  holding a `SKILL.md` is a skill root loaded as one skill with no further
  recursion, while any other directory has its direct `.md` children loaded and its
  subdirectories recursed into for more `SKILL.md` roots; dotfiles and
  `node_modules` are skipped and entries walk in sorted order. `Skills.load_skills`
  merges skills from a list of explicit paths (files or directories), deduplicating
  the same underlying file reached through a symlink by `File.realpath` and
  resolving name collisions first-wins, where a later skill of an already-taken name
  is dropped and recorded as a `collision` diagnostic naming the winning and losing
  files. `Skills.format_for_prompt` renders the `<available_skills>` block a system
  prompt advertises, hiding skills with model invocation disabled. Ports pi's
  `parseFrontmatter`, `loadSkillFromFile`, `validateName`, `validateDescription`,
  `loadSkillsFromDir`, `loadSkills`, and `formatSkillsForPrompt`; pi's
  `includeDefaults` config-directory resolution (the port has no config subsystem
  yet) stays deferred to a later slice. `Truffle::Ignore` is the standalone
  gitignore-style matcher pi layers over that walk: `add(patterns)` compiles
  `.gitignore`/`.ignore`/`.fdignore` lines (comments, blank lines, trailing-space
  handling, `!` negation with last-match-wins, leading and embedded `/` anchoring,
  trailing `/` directory-only, `*`/`**`/`?`/`[...]` globbing, and match-at-any-depth
  for unanchored names) and `ignores?(path)` tests a posix relative path, excluding
  any child of an excluded directory. A faithful zero-dependency port of the
  `ignore` npm package's gitignore-to-regex pipeline, case-insensitive like pi's
  default. `Skills.load_dir` now threads this matcher through its recursive walk:
  at each directory level the `.gitignore`/`.ignore`/`.fdignore` files are read and
  their patterns prefixed with the directory's root-relative path (so a nested
  ignore file scopes to its own subtree), and every entry is tested before it is
  loaded or descended into, with an ignored `SKILL.md` falling through to its
  subdirectories. Ports pi's `addIgnoreRules`, `prefixIgnorePattern`, and
  `toPosixPath`, closing the Skills item end to end.
- Branch summaries. `Session#branch_with_summary` branches like `Session#branch`
  but also drops a `branch_summary` entry on the new path carrying a digest of the
  turns it came back past. The digest folds into `Session#context` as a user
  message wrapped so the model knows it is reading a summary of an abandoned
  branch, while the abandoned entries themselves stay out of context. Passing nil
  branches from the root; an optional `details:` rides along for callers but is
  never sent to the model and is omitted from the entry when absent. The summary
  survives a reload and flows through compaction's kept window like any other
  message. Ports pi's `SessionManager#branchWithSummary` and the branch_summary
  arm of its context walk.
- Session branching and labels. `Session#branch` moves the leaf back to an
  earlier entry so the next append opens a second child, a new branch that leaves
  the abandoned path on disk; `Session#reset_leaf` rewinds to before any entry to
  re-edit the first message. `Session#children` and `Session#entry` read the
  tree. `Session#append_label_change` / `Session#label` attach a user bookmark to
  any entry; the label rides along as its own entry (advancing the leaf) but
  never enters the model context, and resolves through an index that survives a
  reload, last write winning and an empty label clearing. Ports pi's
  `SessionManager#branch` / `resetLeaf` / `getChildren` / `appendLabelChange` /
  `getLabel`.
- Tool middleware: `Agent.new` takes optional `before_tool_call:` and
  `after_tool_call:` callables that wrap tool execution without changing tool
  definitions. `before_tool_call` runs after the tool is resolved and can veto a
  call by returning `{ block: true, reason: ... }`, in which case the reason
  becomes the tool result and the tool never runs. `after_tool_call` runs on an
  executed result (including one from a tool that raised) and can override it by
  returning `{ result: ... }`. An unknown tool skips both hooks, and a hook that
  raises is folded into an error result rather than killing the loop. Ports pi's
  `beforeToolCall` / `afterToolCall` seam, narrowed to this port's single-string
  tool result.

### Changed
- Reworked the README into a shorter public front door: removed the internal
  project layout section, tightened the first screen, and added a runnable
  support-triage example that exercises multiple application-style tools.
- New sessions now defer writing their JSONL file until the first assistant
  message arrives, matching pi's first-flush behavior and avoiding files for
  abandoned one-user-turn starts. `Session#flush` forces a partial write for
  explicit persistence paths, and `Agent#dump` calls it before returning.
- Provider HTTP failures now carry parsed retry-delay hints. OpenAI, Anthropic,
  and Google parse `retry-after-ms` and `retry-after` headers on failed
  non-streaming calls, expose the delay on the returned error response, and let
  the agent prefer that provider-requested delay over exponential backoff. The
  delay is capped by `retry_settings[:max_delay_ms]` (60 seconds by default,
  0/nil to disable the cap).
- `script/rb` now bind-mounts the current checkout by default, uses the full
  Ruby 3.3 image with a cached bundle volume, and passes provider keys from
  `.env.local`, config files, or the current environment without printing them.
  `TRUFFLE_REPO_VOLUME` remains available for volume-based setups.
- Added `script/check` as the one-command verification path: install/check the
  bundle, run `bundle exec rake test`, then run `bundle exec rubocop` in the
  project container.
- Added opt-in SimpleCov reporting with `COVERAGE=true`, LCOV output for
  Codecov, a Codecov upload step in CI, and public README badges for the repo's
  real CI, coverage, gem, Ruby, style, and license signals.
- Corrected the README provider count: OpenAI, Anthropic, and Google Gemini all
  ship in the box (each with a streaming sibling), and the live-test section now
  documents the per-provider key gating for all three.
- Renamed the project from "Pith" to **Truffle** (gem `truffle`, module
  `Truffle`, repo `truffle-dev/truffle-rb`).
- Reframed as a from-scratch, byte-for-byte-faithful port of
  [pi](https://github.com/earendil-works/pi) with no runtime gem dependencies.
  Dropped the planned `ruby_llm` adapter; every provider is hand-written.

### Fixed
- `Session.load` now migrates older JSONL session files to the current v3 tree
  shape. It fills missing entry ids and parent links, converts compaction
  `first_kept_entry_index` values to `first_kept_entry_id`, normalizes legacy
  field names, and rewrites the file once after migration.
- The shared test helper now loads Minitest's stub/mock support, so the provider
  error-turn tests run under a clean `rake test` without requiring a separate
  manual preload.
- The live OpenAI and Google streaming smoke tests now use deterministic prompts
  and `temperature: 0`, avoiding provider phrasing drift while still verifying
  the streamed text matches the final response.

### Added
- `Truffle::Agent` now runs multiple tool calls from the same assistant turn in
  parallel by default, while appending tool-result messages back to history in
  the assistant's source order. This ports pi's `toolExecution: "parallel"`
  behavior for the current Ruby surface: before hooks preflight calls in order,
  allowed tool bodies run concurrently, after hooks finalize each result, and
  result messages stay ordered for the next model turn. Use
  `tool_execution: :sequential` on an agent, or `execution_mode: :sequential` on
  a tool, for stateful tools that must run one at a time.
- `Truffle::Agent` now auto-retries a turn that failed with a transient error.
  When the `Retry` classifier deems a failed turn transient (a load spike, a 5xx,
  a throttle, a dropped socket) and it is not a context overflow, the agent drops
  the failed turn, waits out an exponential backoff (`base_delay_ms * 2 ** (n-1)`
  from a 2s base), and runs the turn again, up to a retry budget (three by
  default). It emits a `:retry` event per attempt and resets its budget on the
  next turn that is not retried, so each fresh failure gets the full count. The
  failed turn stays in the session for history but is dropped from the live
  context the retry sees. Tune or switch it off with `retry_settings:` at
  construction. Works with or without a session, and runs after overflow recovery
  so the compactor keeps first claim on a window overflow. Ports pi's
  `_prepareRetry`.
- `Truffle::Retry.retryable_assistant_error?(response)` classifies whether a
  failed turn reads as a transient provider or transport error worth restarting:
  a load spike, an HTTP 5xx, a throttle, a network or stream transport failure,
  or explicit provider guidance to retry. Only an error turn carrying a message
  qualifies, and an account or billing limit (a spent quota or budget) is never
  retryable even when it also matches a transient pattern, so a "429 quota
  exceeded" stays non-retryable. `Retry.retryable_patterns` and
  `non_retryable_patterns` return copies of the phrase lists. Ports pi's
  `isRetryableAssistantError`. This is classification, not policy: the companion
  to overflow detection, it tells a future retry policy which failures are worth
  trying again.
- A session-backed `Truffle::Agent` now recovers from context overflow. When a
  turn fails (an error turn whose message matches an overflow phrase) or is
  length-stopped over the window, the agent compacts and, if compaction fired,
  drops the failed turn and runs the turn again on the smaller context. A
  completed answer that overran the window compacts for hygiene but is not
  retried, since the answer is already final. Recovery is attempted once per
  overflow: a second consecutive overflow ends the run with an
  `:overflow_unrecovered` compaction error rather than looping, and an overflow
  that nothing can compact away ends the run too. Recovery is off without a
  session and off when `auto_compact:` is false. Ports pi's `_checkCompaction`
  overflow branch, with the recovery gate reset only on non-overflow turns so a
  repeated length-stop overflow cannot loop forever.
- A failed non-streaming `#chat` now returns an error turn instead of raising:
  a `Response` whose `stop_reason` is `:error` carrying the failure text, with an
  empty message and zero usage. The transport (`#post`) folds a connection or read
  fault (`Timeout::Error`, `IOError`, `SocketError`, `SystemCallError`) into a
  `Providers::Error` first, so a network failure surfaces as the same error turn.
  This matches the streaming paths, which already fold their failures this way
  through the accumulator's `#fail`, and ports pi's contract that a provider never
  throws out of a call. It is the seam the agent loop reads to inspect a failure
  (end on it, or compact and retry on a context overflow).
- `Truffle::Overflow.context_overflow?(response, context_window:)` recognizes a
  turn that failed (or silently degraded) because the prompt exceeded the model's
  context window, across the three ways providers report it: an error message
  matching a known overflow phrase (excluding throttle and rate-limit wording that
  only looks like overflow), a successful turn whose reported input already exceeds
  the window, and a length stop that produced no output with the window all but
  full. The window-relative cases fire only when `context_window:` is given.
  `Overflow.patterns` returns a copy of the phrase list. Ports pi's
  `isContextOverflow`; foundation for overflow-triggered emergency compaction.
- Auto-compaction in the agent loop. A `Truffle::Agent` built with a `session:`
  is session-backed: every message it appends to its running history is mirrored
  into the session, and at the top of each turn it checks the previous response's
  reported context against the model's window. When usage crosses the threshold
  (`Compaction.should_compact?`), the agent summarizes the older turns into a
  session compaction entry and rebuilds its context from the summary plus the
  kept tail before calling the provider, so a long run stays under the window.
  `compaction_settings:` tunes the threshold and retention budget; `auto_compact:
  false` keeps a session-backed agent from ever compacting. A `:compaction` event
  reports each run (with the `CompactionResult`, or the `Compaction::Error` when a
  summarization is aborted or fails). The accumulated usage tally survives a
  compaction. Ports the threshold path of pi's `_checkCompaction` /
  `_runAutoCompaction`.
- `Compaction.prepare_compaction` and `compact`, the assembly half of compaction.
  `prepare_compaction(path_entries, settings)` works out the cut from a session
  path (offline and pure): it carries forward a prior compaction's summary and
  file lists, finds the cut point, maps the first kept index to its entry id,
  splits the summarized history from the split-turn prefix, and gathers the file
  operations the dropped history touched. `compact(preparation, provider, model)`
  turns that into a finished summary: it summarizes the history (or "No prior
  history." for an empty split-turn head), joins a split-turn prefix under the
  turn-context divider, and appends the `<read-files>` / `<modified-files>` tags.
  A summarizer failure surfaces as `Compaction::Error`. Ports pi's
  `prepareCompaction` / `compact`; pure over (provider, model, entries), so the
  provider stubs cleanly in tests.
- Split the compaction port across `lib/truffle/compaction.rb` (the decision,
  cut-point, prompt, and assembly layers) and `lib/truffle/compaction/utils.rb`
  (file tracking and conversation serialization), mirroring pi's own
  `compaction.ts` / `compaction/utils.ts` separation. Both reopen the same
  `Truffle::Compaction` module, so the public surface stays flat.
- The file-operation layer of compaction (`Compaction::FileOperations`,
  `create_file_ops`, `extract_file_ops_from_message`, `compute_file_lists`,
  `format_file_operations`). It collects the read/write/edit paths from an
  assistant turn's tool calls, splits them into read-only and modified lists (a
  file that was both read and modified counts only as modified), and renders them
  as the `<read-files>` / `<modified-files>` metadata tags a compaction summary
  carries. Pure and offline; ports pi's `compaction/utils.ts`. This is what
  `prepareCompaction` and `compact` will append to a summary so a resumed session
  still knows which files the dropped history touched.
- `Compaction.generate_summary` and `generate_turn_prefix_summary`, the summarizer
  half of compaction: they build the prompt (folding in a prior summary or a custom
  focus), cap the summary's own output at a fraction of the reserve budget (0.8 for
  history, 0.5 for a split-turn prefix) clamped to the model's max output, send it
  under `SUMMARIZATION_SYSTEM_PROMPT`, and return the summary text. A cancelled or
  errored run raises `Compaction::Error` carrying `:aborted` or
  `:summarization_failed`, so a caller can tell a deliberate stop from a real
  failure. Ports pi's `generateSummary` / `generateTurnPrefixSummary`; the
  thinking-level option is deferred until the provider seam gains per-call reasoning
  control.
- `Compaction.serialize_conversation`, which renders the messages a cut keeps into
  the labeled plain-text body the summarizing model reads: a user turn is its text,
  an assistant turn is up to three parts (thinking, then text, then tool calls) in
  that fixed order, and a tool result is its text clipped to `TOOL_RESULT_MAX_CHARS`.
  `summarization_prompt` and `turn_prefix_prompt` wrap that body in `<conversation>`
  tags, fold in a prior summary, and append the matching instruction (fresh
  checkpoint, update, or turn-prefix). Ports pi's `serializeConversation` and the
  prompt assembly of `generateSummary` / `generateTurnPrefixSummary`; the model call
  itself stays a later slice.
- `Compaction.find_cut_point`, which chooses where to compact a session: it walks
  the conversation path backward summing the per-message estimate until the recent
  budget is met, then snaps the cut to a user or assistant boundary, never inside a
  tool result, and pulls back over settings entries so the first kept entry is a
  real boundary. When the cut lands inside a turn it reports the turn-start index
  and a split-turn flag. Ports pi's `findCutPoint`, `findValidCutPoints`, and
  `findTurnStartIndex`.
- `Truffle::Compaction`, the decision layer for context compaction, ported from
  the trigger half of pi's compaction. `estimate_tokens` gives a conservative
  per-message token estimate (four characters to a token, an image charged a flat
  budget, a tool call charged its name plus its JSON arguments; the system prompt
  is the locked head and estimates zero). `calculate_context_tokens` reads the
  context size of a provider usage block. `estimate_context_tokens(messages,
  usage:)` estimates a conversation, either purely from characters or, given the
  last known usage, as that measured total plus the estimate of the turns since.
  `should_compact?` reports whether context has crossed the window-minus-reserve
  threshold. `Compaction::Settings` and `DEFAULT_SETTINGS` carry pi's thresholds.
- `Agent#dump` and `Agent.load` to pause and resume an agent through a session
  file. `dump(dir:)` writes a new session: the conversation (the system prompt is
  left out, since it is regenerated from configuration on resume as in pi), a
  `model_change` recording the active model, and the toolbox's tool names in the
  header. `Agent.load(path, provider:, tools:, system_prompt:, model:)` reloads
  the session, rebinds the toolbox by name (every tool the dumped agent had must
  be supplied again, or load raises, since the model may still call it), restores
  the model recorded in the session (overridable with `model:`), and replays the
  history. The provider, the tool implementations, and the system prompt are
  re-supplied because they cannot be serialized. `Session.create` gains an
  optional `tools:` header field for this; it is omitted when empty, so a plain
  message session is written exactly as pi writes it.
- Session settings and compaction entries, and `Session#context`, ported from
  pi's `buildSessionContext`. Alongside message entries, a session can now record
  `append_model_change(provider:, model_id:)`, `append_thinking_level_change`, and
  `append_compaction(summary:, first_kept_entry_id:, tokens_before:)`.
  `Session#context` walks the leaf-to-root path and returns what a resumed agent
  should start from: the thinking level and model in force at the leaf (the
  latest such entry wins), and the messages to feed the model. When the path was
  compacted, those messages are the summary (wrapped in pi's `<summary>` framing)
  followed by the kept tail (the entries from `first_kept_entry_id` onward plus
  everything after the compaction), rather than the full history.
  `Session#messages` still returns the raw history for inspection. pi also lets an
  assistant message carry the active model; `Truffle::Message` has no provider or
  model field yet, so only `model_change` entries set the model for now.
- An append-only session store (`Truffle::Session`), ported from pi's session
  manager. A session is a JSONL file: the first line is a header (`type`,
  `version`, `id`, `cwd`, optional `parent_session`) and every line after it is
  a message entry with its own `id`, the `parent_id` of the entry it follows,
  and a `timestamp`. Entries chain through `parent_id`, so the conversation is
  the leaf-to-root path through the file. `Session.create` writes the header and
  binds to the file, `append_message` appends one line per message and advances
  the leaf, `Session.load` parses the file back (skipping a truncated final
  line, as pi tolerates) and validates the header, and `messages` walks the leaf
  to the root and rebuilds the `Truffle::Message` list in order. Built on two
  new pieces: `Truffle::UUID` (a uuidv7 for the session id so ids sort in
  creation order, and an 8-hex short id for entries, both against the standard
  library) and `Message.from_h` / `Content.from_h`, the inverse of the existing
  `to_h` that rebuilds a turn block by block (tool calls included) when a session
  is read from disk.
- The `grep` built-in tool (`Truffle::Tools.grep`), ported from pi's `grep.ts`.
  It takes a `pattern` (a regular expression, or a literal string when `literal`
  is set), an optional `path` (a file or directory, default the current
  directory), an optional `glob` filter, and the `ignoreCase`, `context`, and
  `limit` switches. It returns `path:line: text` for each match and
  `path-line- text` for context lines, the same shape as pi (and `grep -C`). pi
  shells out to the `rg` binary (auto-downloaded) for the search and `.gitignore`
  handling; that pulls an external Rust tool, which breaks the zero-dependency
  and offline constraints, so this port scans the tree with Ruby's own `Regexp`
  and reuses `find` (and through it the `.gitignore` stack) for the file walk, so
  the same exclusions apply. Binary files (detected by a NUL byte) and unreadable
  files are skipped, as `rg` skips them; long lines are truncated to 500
  characters and the match count and 50KB byte ceiling produce pi's three
  bracketed notices. An empty result returns "No matches found".
- The `find` built-in tool (`Truffle::Tools.find`), ported from pi's `find.ts`.
  It takes a glob `pattern`, an optional `path` (default the current directory),
  and an optional `limit` (default 1000), and returns matching file paths
  relative to the search directory, one per line, posix-separated. pi's default
  implementation shells out to the `fd` binary (auto-downloaded) so it can honor
  `.gitignore`; that pulls an external Rust tool, which breaks the
  zero-dependency and offline constraints, so this port matches the tree
  natively with `Dir.glob` and mirrors pi's pluggable `FindOperations.glob`
  branch: `.git` and `node_modules` are excluded and hidden files are included.
  A bare pattern is prepended with `**/` so a basename like `*.rb` recurses, as
  fd's basename matching does. The result limit and the shared 50KB byte ceiling
  produce pi's bracketed notices, and an empty result returns "No files found
  matching pattern".
- `.gitignore` respect for `find` (`Truffle::Tools::Gitignore`). pi inherits this
  from fd's Rust `ignore` crate; since this port matches the tree itself, the
  rules are evaluated natively per gitignore(5): per-directory `.gitignore`
  files, last-match-wins with `!` negation, anchored (a slash in the pattern)
  versus floating patterns, directory-only trailing `/`, and the leading,
  trailing, and middle `**` forms. A directory excluded by a rule prunes
  everything beneath it, so a file cannot be re-included while its parent stays
  excluded. The hardcoded `.git`/`node_modules` floor and the `.gitignore` stack
  are both applied, mirroring fd's actual output. Not yet covered (faithful
  follow-ups): the global excludesfile, `.git/info/exclude`, `.ignore`/`.fdignore`
  files, and nested-repo boundaries.
- The `edit` built-in tool (`Truffle::Tools.edit`), ported from pi's `edit.ts`
  and the matching core in `edit-diff.ts`. It takes a `path` and an `edits`
  array of `{oldText, newText}` replacements. Each `oldText` is matched against
  the original file (exact match first, then a fuzzy fold that applies NFKC
  normalization, strips per-line trailing whitespace, and folds smart quotes,
  unicode dashes, and special spaces to ASCII), must be unique, and must not
  overlap another edit's match; at least one byte must change. The file's line
  endings (LF or CRLF) and a leading BOM are preserved, and the fuzzy path
  rewrites only the lines a replacement touches, copying every other line back
  byte for byte so unchanged blocks keep their exact content. pi's
  `prepareArguments` is ported too: an `edits` value sent as a JSON string is
  parsed, and a legacy top-level `oldText`/`newText` pair is folded onto the
  list. The error messages match pi verbatim (not found, non-unique, empty
  `oldText`, overlap, no change), so the agent loop reports the same guidance.
  pi's diff and unified-patch rendering feeds only the TUI and pulls in the
  `diff` package, so it is out of scope. Occurrence counting uses an escaped
  regexp split so a single-space `oldText` keeps literal semantics rather than
  Ruby's `split(" ")` whitespace-run behavior.
- The `bash` built-in tool (`Truffle::Tools.bash`), ported from pi's `bash.ts`.
  It runs a command under bash in a bound working directory with stdout and
  stderr combined in command order, and returns the raw output. An optional
  `timeout` (seconds, no default) kills the whole process group on expiry; a
  nonzero exit or a timeout raises with the captured output plus a status line,
  the way pi throws. Output is tail truncated (the end, where errors and results
  live) by the same two limits as `read` (2000 lines or 50KB, whichever hits
  first); when truncated, the full untruncated output is written to a temp file
  and the returned notice points at it. The notice's byte-limit branch reports
  pi's default 50KB constant rather than any applied limit, matching `bash.ts`.
  Truncation reuses a new `Truncate.tail` (a port of pi's `truncateTail`), which
  keeps the last lines or bytes and, for a single line that alone exceeds the
  byte budget, keeps the end of it on a character boundary. pi's streaming,
  memory-bounded `OutputAccumulator` is not ported: the engine buffers the full
  output and truncates at the end, which leaves the observable result identical.
- The `write` built-in tool (`Truffle::Tools.write`), ported from pi's
  `write.ts`. It resolves a path against a bound working directory, creates any
  missing parent directories, and writes UTF-8 content, creating the file or
  overwriting it. It returns a short confirmation naming the byte count and the
  path as passed. pi labels that count "bytes" while measuring `content.length`
  (UTF-16 code units); the port reports `content.bytesize`, the real byte count
  the label promises, which agrees with pi for ASCII and stays correct for
  multibyte content. Path resolution moves into a shared `Truffle::Tools::Path`
  module (a port of pi's `resolveToCwd`): unicode space variants fold to a plain
  space, a single leading `@` is stripped, and `~`/`~/` expand to the home
  directory before resolving against cwd. The `read` tool now resolves through
  the same module. file:// URLs are out of scope, matching read's original
  resolution.
- The `read` built-in tool (`Truffle::Tools.read`), the first concrete
  coding-agent tool, ported from pi's `read.ts`. It reads a UTF-8 text file
  relative to a bound working directory (or by absolute path), with a 1-indexed
  `offset` start line and an optional `limit` on lines returned. Output passes
  through head truncation at 2000 lines or 50KB (whichever is hit first), and a
  large or windowed read appends a continuation notice telling the model the next
  `offset` to use. A single line over the byte limit returns a byte-bounded bash
  fallback instead of flooding the context. The shared truncation utility it
  depends on (`Truffle::Tools::Truncate`, a port of pi's `truncate.ts`) lands
  alongside it for the bash and grep tools to come. Images and macOS path
  variants are out of scope for this text-first port.
- Structured tool results: a tool whose handler returns a Hash or Array (or any
  non-String value) now serializes that return as JSON for the model, the way pi
  stringifies a structured tool result. A String return still passes through
  verbatim, so a tool that formats its own text is unchanged. A value JSON cannot
  represent (Infinity, NaN) falls back to its plain string form rather than
  raising. This replaces the prior Ruby `inspect` rendering, which emitted
  `{:a=>1}` instead of valid JSON.
- Provider resolution from a model reference (`Models.resolve`,
  `Models.provider_for`, `Truffle.resolve_model`), a port of pi's
  `findExactModelReferenceMatch`. A reference is a bare id (`claude-opus-4-8`), a
  canonical `provider/id` (`anthropic/claude-opus-4-8`), or a dated snapshot of
  either; matching trims surrounding space and is case-insensitive. A bare id
  served by more than one provider is ambiguous and resolves to `nil` rather than
  guessing, while a named provider disambiguates it. `Truffle.agent` now accepts
  `model:` without `provider:`: the provider is inferred from the model and a
  `provider/id` reference is reduced to the bare wire id the provider expects. An
  explicit `provider:` is left untouched, so a custom or unlisted model id still
  works when the provider is named.
- A Google Gemini provider (`Providers::Google`, `provider: :google`) over the
  Generative Language API's `generateContent` endpoint, hand-written on
  `Net::HTTP` with no client gem. This is the non-streaming `#chat` half, a port
  of pi's `google-shared.ts`/`google-generative-ai.ts` wire shapes: the system
  prompt is lifted to a top-level `systemInstruction`, messages become Gemini
  `Content` with role `user`/`model`, tool calls are `functionCall` parts, tool
  results coalesce into one `user` turn of `functionResponse` parts, tools carry
  a `parametersJsonSchema`, and `tool_choice` maps to a `functionCallingConfig`
  mode. A thinking block is replayed as a `thought` part only when its signature
  is valid base64 (Gemini's TYPE_BYTES requirement), otherwise downgraded to
  plain text the way pi handles a cross-model replay. Gemini reports a plain
  `STOP` finish even when the turn is a tool call, so the stop reason is
  overridden to `tool_use` when the model asked for one. `Usage.from_google`
  parses `usageMetadata`, taking `input` as the residual after
  `cachedContentTokenCount` and folding `thoughtsTokenCount` into output while
  recording it as reasoning. The model catalog gains the Gemini lineup
  (3.5 Flash, 3.1 Pro Preview, 3.1 Flash-Lite, and the 2.5 Pro/Flash/Flash-Lite
  family) with current per-million pricing.
- A streaming Google provider (`Providers::Google#chat_stream`), the streaming
  counterpart to `#chat`. It opens an SSE request to `streamGenerateContent`
  (with `?alt=sse`) over the shared `Providers::SSE` transport and yields the
  same ordered `Truffle::StreamEvent` protocol the other providers do: one
  `:start`, a `*_start`/`*_delta`/`*_end` trio per block (text, thinking, or tool
  call), and a terminal `:done` or `:error` carrying the final message and
  StopReason. Unlike Anthropic's indexed block events, each Gemini chunk is a
  whole response whose candidate carries the parts produced since the last chunk,
  so the decode keeps one open text-or-thinking block and appends to it, closing
  it and opening a fresh one when the part kind flips (text to thought or back)
  or a `functionCall` arrives. A `functionCall` emits a complete
  `start`/`delta`/`end` trio at once, and the stop reason is overridden to
  `tool_use` when the turn produced a call (Gemini reports a plain `STOP` even
  then). A missing or duplicate call id is replaced with a deterministic
  name-and-counter id; the latest non-empty thought signature is retained; the
  cumulative `usageMetadata` is taken from the last chunk that carries it. The
  decode lives in a pure `Providers::GoogleStream` accumulator fed already-parsed
  chunk hashes, tested fully offline, and reuses every wire transform from
  `#chat`. A `SAFETY`/`RECITATION` finish folds into a terminal `:error`, and an
  `AbortSignal` folds into a clean `:done` with `StopReason::ABORTED`.
- A streaming Anthropic Messages provider (`Providers::Anthropic#chat_stream`),
  the streaming counterpart to `#chat`. It opens an SSE request and yields the
  same ordered `Truffle::StreamEvent` protocol the OpenAI provider does: one
  `:start`, a `*_start`/`*_delta`/`*_end` trio per content block (text, thinking,
  redacted thinking, or tool call), and a terminal `:done` or `:error` carrying
  the final message and StopReason. The decode lives in a pure
  `Providers::AnthropicStream` accumulator fed already-parsed event hashes, so it
  is tested fully offline: `message_start` seeds the response id and usage, each
  `content_block_start`/`delta`/`stop` drives one block keyed by its wire index,
  and `message_delta` carries the stop reason and final usage. Input tokens read
  at `message_start` survive a `message_delta` that omits them, while the delta's
  `output_tokens` wins. `tool_use` arguments assemble from `input_json_delta`
  fragments and parse once the block stops; a malformed buffer surfaces under a
  `_raw` key rather than crashing. A mid-stream `error` event, a `refusal`, or a
  stream that ends before `message_stop` all fold into a terminal `:error`, and
  an `AbortSignal` folds into a clean `:done` with `StopReason::ABORTED` carrying
  whatever content arrived. The SSE transport shared by both providers is
  factored into a `Providers::SSE` mixin (`#stream_post`, `#drive_stream`, line
  buffering, and tolerant data-line decode); each provider supplies only its auth
  headers and error label, so the two streaming paths cannot drift.
- A structured model catalog (`Truffle::Models`, `Truffle::Model`), the single
  source of truth for every model Truffle can address. Each `Model` carries its
  id, name, provider, api, context window, max output, input modalities,
  reasoning support, a deprecation flag, and a per-million-token cost hash
  (`:input`, `:output`, `:cache_read`, `:cache_write`), mirroring the fields pi
  keeps in its generated `*.models.ts` tables. The Anthropic and OpenAI lineups
  are transcribed from each provider's published model and pricing docs and kept
  current (Claude Fable 5, Opus 4.8 through 4.5, Sonnet 4.6/4.5, Haiku 4.5; the
  GPT-5.5/5.4/5 families, GPT-4.1, GPT-4o). `Truffle.models` lists them all and
  `Truffle.model(id)` resolves one, accepting a dated snapshot id
  (`gpt-4o-2024-08-06`, `claude-sonnet-4-5-20250929`) as its base model.
  `Truffle::Pricing` is now a thin facade reading rates off the catalog, so
  pricing can never drift from the model list. A freshness test fails loudly if
  the current flagships ever regress to a stale lineup.
- A native Anthropic Messages provider (`Providers::Anthropic`), ported from pi's
  `anthropic-messages.ts` wire shapes and hand-written on `Net::HTTP` with no
  client gem. `Truffle.agent(provider: :anthropic)` drives a full tool round
  trip. The request body follows the Messages API: the system prompt is lifted
  out of the message list into the top-level `system` field, `max_tokens` is
  always sent because the API requires it, message content is a block array, tool
  calls are `tool_use` blocks, and tool results come back as a `user` message of
  `tool_result` blocks with consecutive results coalesced into one message. Tool
  schemas go under `input_schema`. Assistant replay handles pi's edge cases: an
  empty text block is dropped, a redacted thinking block round-trips as
  `redacted_thinking`, and an unsigned thinking block is downgraded to plain text
  since Anthropic rejects unsigned thinking on replay. Stop reasons map onto
  `Truffle::StopReason` (`end_turn`/`stop_sequence`/`pause_turn` to stop,
  `max_tokens` to length, `tool_use` to tool use, `refusal`/`sensitive` to error
  with an explanation), and an unknown reason folds to an error carrying the raw
  string rather than crashing the loop. Usage is read with `Usage.from_anthropic`:
  `input_tokens` is taken directly (Anthropic reports it net of cache, unlike
  OpenAI's residual), and the 1h cache write is billed at twice base input.
  `Pricing` gains the Anthropic per-million-token table, and `base_model` now
  strips both date-snapshot forms (OpenAI's dashed `-2024-08-06` and Anthropic's
  compact `-20250929`). This is the non-streaming `#chat` half; the streaming
  `#chat_stream` over the same transforms is its own entry above.
- Cooperative cancellation, ported from pi's `AbortSignal` threading through the
  agent loop and the streaming reader. `Truffle::AbortSignal` is a thread-safe
  token (`#abort`, `#aborted?`, `#reason`, and an `AbortSignal.aborted`
  constructor) that the owner of a run can trip from any thread. `Agent#run`
  takes `signal:` and checks it at turn boundaries, the point reached before each
  provider call and again after a batch of tool calls, so an abort stops the loop
  mid-flight and ends with a `StopReason::ABORTED` terminal instead of starting
  another turn. `Providers::OpenAI#chat_stream` takes `signal:` and checks it
  between socket reads; on cancel it stops reading and folds the turn into a clean
  `:done` terminal carrying `StopReason::ABORTED` and whatever content arrived,
  not an `:error`. Cancellation is cooperative: an in-progress provider call or a
  stalled socket read finishes or times out rather than being force-killed.
- Token usage and cost accounting, ported from pi's `Usage` type plus its
  `parseChunkUsage` and `calculateCost` helpers. `Truffle::Usage` is a value
  object carrying `input`, `output`, `cache_read`, `cache_write`, `reasoning`,
  and `total_tokens`, with a `cost` sub-struct in dollars. `Usage.parse` reads a
  provider's raw usage hash the way pi does: cache reads come from
  `prompt_tokens_details.cached_tokens` (falling back to `prompt_cache_hit_tokens`),
  and `input` is the residual so a cached prompt token is billed once as a read,
  not also as fresh input. `Truffle::Pricing.cost_for` looks up per-million-token
  rates by model id (stripping a date snapshot suffix; unknown models price at
  zero but still count tokens). `Response#usage` is now a `Usage`, and the agent
  sums usage across every turn of every run, exposing the running total on
  `agent_end` and clearing it on `#reset`.
- Streaming and the event protocol, ported from pi's `AssistantMessageEvent`
  stream. `Providers::OpenAI#chat_stream` opens an SSE request and yields ordered
  `Truffle::StreamEvent` objects as a turn arrives: one `:start`, then a
  `*_start`/`*_delta`/`*_end` trio per content block (text, thinking, or tool
  call), and a terminal `:done` or `:error` carrying the final message and
  StopReason. Each non-terminal event also carries a `partial` snapshot of the
  message so far. The decode logic lives in `Providers::OpenAIStream`, an
  accumulator fed parsed chunk hashes so it is tested fully offline; the HTTP and
  SSE transport stays in `#chat_stream`. A transport or parse failure folds into
  the stream as an `:error` event rather than raising, mirroring pi. The
  non-streaming `#chat` path and the agent loop are unchanged.
- Stop reasons, ported from pi's `StopReason` union
  (`stop`/`length`/`toolUse`/`error`/`aborted`). `Truffle::StopReason` holds the
  canonical set as symbols (`:stop`, `:length`, `:tool_use`, `:error`,
  `:aborted`); `Truffle::Providers::OpenAI.map_stop_reason` maps a Chat
  Completions `finish_reason` onto one (a faithful port of pi's `mapStopReason`),
  returning an error message for failure reasons. `Response#stop_reason` and
  `#error_message` carry the result, and the agent emits both on `agent_end`, so
  a caller can tell a clean finish from a length truncation or a content-filter
  error. The raw provider string stays available on `Response#finish_reason`.
- Typed content blocks (`Truffle::Content::Text`, `::Thinking`, `::Image`),
  ported from pi's content model. A `Message`'s content is now a list of these
  blocks instead of a single string; a bare String is wrapped as one Text block,
  and the model's tool calls live in the same list as `ToolCall` blocks rather
  than a side channel. `Message#text` joins the Text blocks; `#tool_calls` and
  `#tool_calls?` read off the content list. The public API is unchanged for the
  common case.
- RuboCop linting with a tuned house-style config, plus a CI workflow that runs
  the offline suite across Ruby 3.1–3.4 (and `head`, allowed to fail), a RuboCop
  lint job, and a `gem build` packaging check, each a required gate.
- Published to RubyGems: `gem install truffle`.
- `docs/RELEASING.md`: versioning, changelog, publish, and upgrade flow.
- Rewritten `ROADMAP.md` mapping Phases 1–5 to pi's package structure.

## [0.1.0] - 2026-06-28

First release. The agent-core runtime, ported from
[pi](https://github.com/earendil-works/pi) to plain Ruby.

### Added
- `Truffle::Agent`: the agent loop (prompt -> tool calls -> tool results -> answer)
  with a `max_turns` guard and an ordered event stream.
- Tool DSL via `Truffle.tool` / `Truffle::Tool.define`: typed params, JSON Schema
  generation, string-key to keyword-arg symbolization, and error capture that
  feeds tool failures back to the model instead of crashing the loop.
- `Truffle::Toolbox`: a named, enumerable collection of tools.
- Provider seam (`Truffle::Providers::Base`) and a dependency-free OpenAI Chat
  Completions provider built on `Net::HTTP`.
- Event API (`Agent#on`) for `agent_start`, `turn_start`, `message`,
  `tool_call`, `tool_result`, `turn_end`, `agent_end`.
- `examples/calculator.rb`: a runnable multi-tool demo.
- Test suite: hermetic minitest tests plus one live OpenAI round-trip test,
  skipped unless `OPENAI_API_KEY` is set.
- `script/rb`: run any command in a `ruby:3.3-slim` container for hosts without
  a local Ruby.

[Unreleased]: https://github.com/truffle-dev/truffle-rb/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/truffle-dev/truffle-rb/releases/tag/v0.1.0
