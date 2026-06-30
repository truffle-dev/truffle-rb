# Roadmap

Truffle is a byte-for-byte-faithful Ruby port of
[pi](https://github.com/earendil-works/pi), grown into a complete agent harness
with skills, commands, sessions, and memory. Everything is written from scratch
in plain Ruby with no runtime gem dependencies.

Truffle grows slowly and steadily: one focused, tested increment at a time. Each
item below is a self-contained slice. When you pick one up, ship it with tests
green and a clear commit, then check it off here in the same commit. Do not
bundle items. Keep the core loop in `lib/truffle/agent.rb` readable.

The ordering is a current best guess, not a contract. Read pi's real source
before each slice and let the port dictate the shape. If a better next slice
appears, add it; the goal is faithfulness to pi, then reach beyond it.

## Done (v0.1.0)

- [x] Tool DSL with typed params and JSON Schema generation
- [x] Toolbox (named, enumerable tool collection)
- [x] Message / ToolCall / Response value objects
- [x] Provider seam (`Providers::Base`)
- [x] OpenAI Chat Completions provider (dependency-free, `Net::HTTP`)
- [x] Agent loop with `max_turns` guard
- [x] Ordered event API (`agent_start` ... `agent_end`)
- [x] Error capture: a raising tool is reported back to the model
- [x] Hermetic test suite + one live OpenAI round-trip test
- [x] `script/rb` container runner; calculator example; docs; CI

## Phase 1: faithful agent-core port

Match pi's `packages/agent` and the type system in `packages/ai/src/types.ts`.

1. [x] **Content blocks.** Port pi's content model: text, thinking, image, and
   tool-call blocks on assistant messages; text/image/tool-result on user
   messages. A message is a list of typed blocks, not a single string.
2. [x] **Stop reasons.** Port `StopReason` (`stop` / `length` / `toolUse` /
   `error` / `aborted`) and surface it on the response and on `agent_end`.
3. [x] **Streaming + the event protocol.** Port pi's `AssistantMessageEvent`
   stream (`start`, `text_start/delta/end`, `thinking_*`, `toolcall_*`, `done`,
   `error`). A `chat_stream` path on the provider seam drives it; non-streaming
   `run` keeps working unchanged.
4. [x] **Usage + cost.** Aggregate `Usage` across turns; expose it on
   `agent_end`; add per-provider/model cost estimation.
5. [x] **Abort.** A cancellation signal that stops the loop mid-flight and yields
   an `aborted` stop reason cleanly.

## Phase 2: LLM layer parity (the `ai` package)

6. [x] **Anthropic provider.** Native, over the Messages API, with its tool-use
   content-block shape. Hand-written, no client gem. Both halves landed:
   non-streaming `#chat` and streaming `#chat_stream` over the same transforms,
   the latter decoding through an `AnthropicStream` accumulator and sharing the
   SSE transport with OpenAI via the `Providers::SSE` mixin.
7. [x] **Google / Gemini provider.** Native, over the Generative Language API,
   hand-written, no client gem. Both halves landed: non-streaming `#chat` over
   `generateContent` (`systemInstruction` extraction, `Content` role mapping,
   `functionCall`/`functionResponse` parts with single-user-turn coalescing,
   `parametersJsonSchema` tools, thought-signature handling, the `STOP`-to-
   `tool_use` override, `Usage.from_google`, and the Gemini catalog lineup), and
   streaming `#chat_stream` over `streamGenerateContent` (`?alt=sse`), decoding
   through a `GoogleStream` accumulator that keeps one open text-or-thinking
   block per chunk and emits a whole `functionCall` trio at once, sharing the SSE
   transport with OpenAI and Anthropic via the `Providers::SSE` mixin.
8. **Model catalog + provider registry.**
   - [x] **Model catalog.** A structured registry (`Truffle::Models`,
     `Truffle::Model`) of every model Truffle can address: id, provider, api,
     context window, max output, modalities, reasoning, deprecation, and a
     per-token cost hash, mirroring pi's generated `*.models.ts` tables and kept
     current to each provider's published docs. `Pricing` reads its rates; a
     freshness test guards against the lineup going stale.
   - [x] **Provider resolution.** Resolve a bare `model:` string to the right
     provider automatically the way pi's `ai` package does, so the caller need
     not also name the provider. `Models.resolve` ports pi's
     `findExactModelReferenceMatch` (bare id, canonical `provider/id`, dated
     snapshots, case-insensitive, ambiguity rejected); `Truffle.agent` infers the
     provider from `model:` and reduces a `provider/id` reference to the bare wire
     id.
9. [x] **Structured tool results.** A tool may return a hash/array, serialized
   as JSON for the model; plain strings keep working. `Tool#call` serializes any
   non-String return with `JSON.generate` (Infinity/NaN fall back to `to_s`),
   mirroring pi's `JSON.stringify` of a structured result.

## Phase 3: the coding-agent surface

Match `packages/coding-agent`: the tools and runtime that make an actual agent.

10. **Built-in tools.** bash, read, write, edit, find, grep, written from
    scratch, matching pi's tool contracts and safety behavior.
    - [x] **read.** `Truffle::Tools.read` ports pi's `read.ts` text path: a
      `path` resolved against a bound cwd (or absolute), a 1-indexed `offset`, an
      optional line `limit`, head truncation at 2000 lines / 50KB via the shared
      `Truffle::Tools::Truncate` (a port of `truncate.ts`), and pi's continuation
      notices. Text-first: images and macOS path variants are out of scope.
    - [x] **write.** `Truffle::Tools.write` ports pi's `write.ts`: resolve the
      `path` against cwd, mkdir -p the parent, write UTF-8 content (create or
      overwrite), and confirm with the byte count (`content.bytesize`, the count
      the "bytes" label promises) and the path. Path resolution moves into the
      shared `Truffle::Tools::Path` (a port of `resolveToCwd`: unicode-space fold,
      `@`-strip, `~` expansion); `read` now resolves through it too.
    - [x] **bash.** `Truffle::Tools.bash` ports pi's `bash.ts`: run a command
      under bash in a bound cwd, stdout and stderr combined in order, optional
      `timeout` (seconds) that kills the process group, nonzero exit / timeout
      raises with output plus a status line. Tail truncation via a new
      `Truncate.tail` (port of `truncateTail`), full output to a temp file when
      truncated. The streaming `OutputAccumulator` is deferred; buffering the
      full output keeps the observable contract identical.
    - [x] **edit.** `Truffle::Tools.edit` ports pi's `edit.ts` plus the matching
      core in `edit-diff.ts`: a `path` and an `edits` array of `{oldText,
      newText}`. Each `oldText` is matched against the original (exact first,
      then a fuzzy fold of NFKC, per-line trailing-whitespace strip, smart
      quotes, unicode dashes, and special spaces), must be unique and
      non-overlapping, and at least one byte must change. Line endings and a
      leading BOM are preserved; the fuzzy path rewrites only touched lines and
      copies the rest back byte for byte. `prepareArguments` (JSON-string
      `edits`, legacy top-level `oldText`/`newText`) is ported. The diff and
      unified-patch rendering feeds only pi's TUI and pulls in the `diff`
      package, so it is out of scope.
    - [x] **find.** `Truffle::Tools.find` ports pi's `find.ts` execute path: a
      `pattern`, an optional `path` (default `.`), and an optional `limit`
      (default 1000). pi shells out to the `fd` binary so it can honor
      `.gitignore`; that pulls an external Rust tool, so this port matches the
      tree natively with `Dir.glob`, mirroring pi's pluggable
      `FindOperations.glob` branch: `.git` and `node_modules` are excluded and
      hidden files are included. A bare pattern is prepended with `**/` so it
      recurses; paths are returned relative to the search root, posix-separated.
      The result limit and the 50KB byte ceiling produce pi's bracketed
      notices.
    - [x] **gitignore respect for find.** `Truffle::Tools::Gitignore` evaluates
      the per-directory `.gitignore` stack natively (what pi gets from fd's
      `ignore` crate): last-match-wins negation, anchored versus floating
      patterns, directory-only trailing `/`, the `**` forms, and the prune rule
      (an excluded directory can't have a child re-included). Applied alongside
      the hardcoded `.git`/`node_modules` floor.
    - [x] **grep.** `Truffle::Tools.grep` ports pi's `grep.ts` execute path: a
      `pattern` (regex, or literal when `literal` is set), an optional `path`
      (file or directory, default `.`), an optional `glob`, and the `ignoreCase`,
      `context`, and `limit` switches. It returns `path:line: text` for matches
      and `path-line- text` for context, as pi (and `grep -C`) do. pi shells out
      to `rg`; that pulls an external Rust tool, so this port scans with Ruby's
      `Regexp` and reuses `find` for the walk. Binary (NUL-byte) and unreadable
      files are skipped, long lines truncate at 500 chars, and the match count
      and 50KB ceiling produce pi's three notices.
    - [x] **gitignore respect for grep.** Inherited for free: grep's file walk
      runs through `find`, so the same `.gitignore` stack and `.git`/`node_modules`
      floor apply.
11. **Sessions + persistence.** `Agent#dump` / `Agent.load` to round-trip a
    session (history + tool definitions by name) so it can be paused and resumed.
    - [x] **Session store.** `Truffle::Session`: an append-only JSONL file (header
      line + message entries chained through `parent_id`) that round-trips a
      message history via `create` / `append_message` / `load` / `messages`,
      built on a new `Truffle::UUID` (uuidv7 session ids, 8-hex entry ids) and
      `Message.from_h` / `Content.from_h` deserialization. Faithful to pi's
      session-manager structure; the leaf-to-root walk is the conversation.
    - [x] **Settings and compaction entries + `Session#context`.**
      `append_model_change` / `append_thinking_level_change` /
      `append_compaction`, and a context reader (pi's `buildSessionContext`) that
      recovers the live thinking level and model and, after a compaction, returns
      the summary plus the kept tail instead of the full history.
    - [x] **Branching and labels.** `Session#branch` moves the leaf back to an
      earlier entry so the next append opens a second child (a new branch off a
      node, leaving the abandoned path on disk); `Session#reset_leaf` rewinds to
      before any entry. `Session#children` / `Session#entry` read the tree.
      `Session#append_label_change` / `Session#label` attach a user bookmark to
      any entry, resolved through an index that survives a reload (last write
      wins, an empty label clears); a label entry advances the leaf but stays out
      of the model context. Ports pi's `branch` / `resetLeaf` / `getChildren` /
      `appendLabelChange` / `getLabel`.
    - [x] **Branch summaries.** `Session#branch_with_summary` branches and drops a
      `branch_summary` entry digesting the abandoned path; the digest folds into
      `#context` as a wrapped user message while the abandoned entries stay out of
      context. Ports pi's `branchWithSummary` and the branch_summary arm of the
      context walk.
    - [x] **Deferred-first-flush optimization.** New sessions buffer their header
      and early entries until the first assistant message arrives, avoiding files
      for abandoned one-user-turn starts. `Session#flush` forces a partial write
      for explicit persistence paths such as `Agent#dump`.
    - [x] **v1/v2 file migration.** `Session.load` upgrades older JSONL files
      to the current v3 tree shape: missing entry ids/parents are filled in
      linearly, compaction `first_kept_entry_index` values become
      `first_kept_entry_id`, legacy field names are normalized, and the migrated
      file is rewritten once.
    - [x] `Agent#dump` / `Agent.load` wired onto the session store, persisting
      tool definitions by name so a resumed agent rebinds its toolbox. `dump`
      writes the conversation (no system prompt, regenerated on resume), a
      `model_change` for the active model, and the tool names in the header;
      `load` rebinds the toolbox by name (raising on a missing tool), restores the
      model, and replays the history. The provider, tools, and system prompt are
      re-supplied since they cannot be serialized.
12. **Compaction.** Summarize old turns to stay under context, preserving a
    locked, non-removable head (system prompt, pinned facts), mirroring how pi
    compacts.
    - [x] **Decision layer.** `Truffle::Compaction` ports pi's trigger half:
      `estimate_tokens` (per-message character heuristic, flat image budget, tool
      call charged name plus JSON arguments, system prompt excluded as the locked
      head), `calculate_context_tokens` (context size of a usage block),
      `estimate_context_tokens` (pure estimate, or measured usage plus the
      trailing turns since), and `should_compact?` against the window-less-reserve
      threshold, with `Settings` / `DEFAULT_SETTINGS`.
    - [x] **Cut-point selection.** `Compaction.find_cut_point` ports pi's
      `findCutPoint` / `findValidCutPoints` / `findTurnStartIndex`: walk the
      session path backward summing `estimate_tokens` until the recent-token
      budget is met, snap to a user or assistant boundary (never mid tool-result),
      pull back over settings entries, and record the split-turn case
      (`turn_start_index`, `split_turn`).
    - [x] **Prompt building.** `Compaction.serialize_conversation` renders the kept
      messages into the labeled plain-text body the summarizer reads (user text,
      ordered assistant thinking/text/tool-calls, tool results clipped to
      `TOOL_RESULT_MAX_CHARS`), and `summarization_prompt` / `turn_prefix_prompt`
      wrap it with the prior summary and the four verbatim pi prompt strings. Pure
      and offline; ports pi's `serializeConversation` and `generateSummary` /
      `generateTurnPrefixSummary` prompt assembly.
    - [x] **Summarizer provider call.** `Compaction.generate_summary` and
      `generate_turn_prefix_summary` build the prompt, cap the summary output at a
      fraction of the reserve (0.8 history, 0.5 split-turn prefix) clamped to the
      model max, call the provider under `SUMMARIZATION_SYSTEM_PROMPT`, and return
      the summary text, raising `Compaction::Error` (`:aborted` /
      `:summarization_failed`) on a cancelled or errored run. Ports pi's
      `generateSummary` / `generateTurnPrefixSummary`; thinking-level passthrough
      deferred until the provider seam has per-call reasoning control.
    - [x] **File operations in summaries.** `Compaction::FileOperations` and the
      `create_file_ops` / `extract_file_ops_from_message` / `compute_file_lists` /
      `format_file_operations` functions collect the read/write/edit paths from an
      assistant turn's tool calls, split them into read-only and modified lists (a
      file both read and modified counts only as modified), and render them as the
      `<read-files>` / `<modified-files>` tags a summary carries. Pure and offline;
      ports pi's `compaction/utils.ts`.
    - [x] `prepareCompaction` + `compact`: assemble the summary from a cut (the
      split-turn prefix and the file-ops tags), pure over (provider, model,
      entries). Ports pi's `prepareCompaction` / `compact`.
    - [x] Drive compaction from the agent loop: `should_compact?` at the top of
      `Agent#run`, then `compact` and an `append_compaction` entry carrying the
      cut's `first_kept_entry_id` and file-ops `details`, then rebuild context.
    - [x] `Overflow.context_overflow?`: detect a window-overflowed turn from its
      error phrase, a silent over-window `stop`, or a zero-output `length` stop.
      Ports pi's `isContextOverflow`. Foundation for overflow-triggered compaction.
    - [x] Provider error surface: a failed non-streaming `#chat` returns an error
      turn (`stop_reason :error` + `error_message`) instead of raising, and `#post`
      folds a transport fault into `Providers::Error` first. Matches the streaming
      paths and ports pi's never-throw-out-of-a-provider contract. This carries the
      overflow signal the recovery branch reads.
    - [x] Drive overflow recovery from the agent loop: on an overflowed turn,
      run a one-shot emergency compaction and retry (pi's overflow branch +
      `_overflowRecoveryAttempted`). Compact-only on a completed over-window
      answer; give up after one attempt or when nothing can be compacted. The
      gate resets only on non-overflow turns, so a repeated length-stop overflow
      cannot loop forever.
    - [x] Tool-message pairing coverage: `test/test_compaction_tool_messages.rb`
      builds fixtures from real `assistant(tool_call)` / `tool(result)` pairs and
      asserts a tool result is never separated from its call across three cut
      shapes (clean cut, split turn, prior-compaction continuation), on both the
      summarized history and the rebuilt session context. Mutation-proven against
      a `valid_cut_points` that admits tool results.
13. **Retries + timeouts.** Configurable HTTP timeout and bounded backoff in each
    provider; typed errors.
    - [x] `Retry.retryable_assistant_error?`: classify whether a failed error turn
      reads as a transient provider/transport error (load, 5xx, throttle, network,
      premature stream end, explicit retry guidance) vs a non-retryable account or
      billing limit. Ports pi's `isRetryableAssistantError`. Classification only;
      the policy below consumes it.
    - [x] Configurable HTTP open/read timeout per provider call (all three
      providers take `open_timeout:`/`read_timeout:` and apply them in `#post`).
    - [x] Bounded backoff retry policy: `Agent` restarts a turn that `Retry` deems
      transient, capped by a retry budget, with exponential backoff. Ports pi's
      `_prepareRetry`.
    - [x] Provider retry-delay headers: failed HTTP calls parse
      `retry-after-ms` and `retry-after` (seconds or HTTP-date), carry the delay
      on the returned error response, and let the agent prefer it over
      exponential backoff, capped by `retry_settings[:max_delay_ms]` (60s by
      default, 0/nil to disable the cap). Ports the provider-delay behavior pi
      applies before falling back to exponential retry delays.
14. [x] **Tool middleware.** before/after hooks around tool execution (logging,
    auth, rate limiting) without changing tool definitions. `Agent.new` takes
    `before_tool_call:` (veto a call with `{ block: true, reason: }`) and
    `after_tool_call:` (override the result with `{ result: }`), ported from pi's
    `beforeToolCall` / `afterToolCall`. The before hook runs after the tool
    resolves; the after hook runs on an executed result; an unknown tool skips
    both; a raising hook becomes an error result. Narrowed to this port's
    single-string tool result (no structured content/details/isError/terminate).
15. [x] **Parallel tool dispatch.** Run independent tool calls in one turn
    concurrently while preserving result ordering in the history. The agent now
    defaults to `tool_execution: :parallel`: it preflights tool calls in source
    order, runs allowed tool bodies concurrently, and appends tool-result
    messages in source order. `tool_execution: :sequential` on the agent, or
    `execution_mode: :sequential` on any tool in the batch, keeps the historical
    one-at-a-time behavior.
    - [x] **System prompt assembly.** `Truffle::SystemPrompt.build` ports pi's
      `core/system-prompt.ts` `buildSystemPrompt`: the pure string the agent runs
      under, in either the custom-prompt branch or the default coding-agent branch,
      with the tools list (a tool shows only when the caller supplies a non-empty
      one-line snippet), deduplicated insertion-ordered guidelines (the bash-only
      exploration heuristic, caller guidelines trimmed, the two always-on lines),
      the `<project_context>` block, the read-tool-gated `<available_skills>` block
      via `Skills.format_for_prompt`, and the trailing date and cwd. The default
      prompt names Truffle and its documentation pointer references the gem's
      bundled README and examples; the date is injectable so tests stay
      deterministic.
    - [x] **Project context-file loader.** `Truffle::ContextFiles.load` ports pi's
      `core/resource-loader.ts` `loadProjectContextFiles`: it discovers the
      `AGENTS.md` / `CLAUDE.md` instruction files that feed `SystemPrompt.build`'s
      `<project_context>` block. The global agent-directory file comes first, then
      the chain from the filesystem root down to the working directory so the
      nearest file lands last; within one directory the first existing candidate
      wins (`AGENTS.md` over `CLAUDE.md`), a file reachable by more than one route
      appears once, and an unreadable candidate warns and falls through to the next
      name. The warning sink is injectable so tests stay quiet.

## Phase 4: self-extension (skills, commands, extensions)

16. **Skills.** A skill is a markdown file with frontmatter and instructions,
    loadable at runtime, the way pi loads skills.
    - [x] **Frontmatter parser.** `Truffle::Frontmatter` ports pi's
      `parseFrontmatter` / `extractFrontmatter`: the YAML block between a leading
      `---` and the next `---`, with the trimmed body, normalizing newlines and
      treating an absent or unclosed block as all body.
    - [x] **Single-file load + validation + prompt format.** `Truffle::Skills`
      ports pi's `loadSkillFromFile` / `validateName` / `validateDescription` /
      `formatSkillsForPrompt`: one markdown file into a `Skill` plus diagnostics
      (name falls back to the parent directory, a blank description drops the
      skill, other problems warn but load), and `format_for_prompt` renders the
      `<available_skills>` block, hiding skills with model invocation disabled.
    - [x] **Directory discovery.** `Skills.load_dir` ports pi's
      `loadSkillsFromDir`: a `SKILL.md` makes a directory a skill root and stops
      recursion; otherwise direct `.md` children load and subdirectories recurse
      for more `SKILL.md` roots, skipping dotfiles and `node_modules`.
    - [x] **Multi-source merge.** `Skills.load_skills` ports pi's `loadSkills`:
      it merges skills from a list of explicit paths, deduplicating the same file
      reached via a symlink by `File.realpath` and resolving name collisions
      first-wins (a later same-name skill becomes a `collision` diagnostic). pi's
      `includeDefaults` config-directory resolution is deferred until the port
      grows a config subsystem.
    - [x] **Gitignore-style matcher.** `Truffle::Ignore` hand-rolls pi's
      `ignore`-package matcher zero-dep: `add(patterns)` compiles gitignore lines
      and `ignores?(path)` tests a posix relative path with last-match-wins
      negation, `/` anchoring, `*`/`**`/`?`/`[...]` globbing, directory-only
      trailing `/`, and ancestor-directory exclusion, case-insensitive like pi's
      default. Validated by a 1450-comparison differential against the real
      `ignore` package.
    - [x] **Wire `Truffle::Ignore` into the discovery walk.** `Skills.load_dir`
      threads one matcher and the scan root through its recursion, folding in the
      `.gitignore`/`.ignore`/`.fdignore` files at each level (patterns prefixed with
      the directory's root-relative path) and pruning every entry before it loads,
      with an ignored `SKILL.md` falling through to its subdirectories. Ports pi's
      `addIgnoreRules`/`prefixIgnorePattern`/`toPosixPath`. Item 16 is closed.
17. **Commands.** User-invocable commands that expand into prompts/actions.
    - [x] **Prompt-template arguments.** `Truffle::PromptTemplates` ports pi's
      pure prompt-template argument layer: bash-style quoted arg parsing and
      single-pass substitution for `$1`, `$@`, `$ARGUMENTS`, `${N:-default}`,
      `${@:N}`, and `${@:N:L}` placeholders.
    - [x] **Prompt markdown loading from explicit paths.**
      `Truffle::PromptTemplates` loads prompt `.md` files from named files and
      direct directory scans, preserves `description` and `argument-hint`
      frontmatter, falls back to the first body line for descriptions, and
      expands `/name args` with the argument helpers.
    - [x] **Default command/prompt directories.** `Truffle::Config` defines the
      Ruby config layout (`~/.truffle/agent` or `TRUFFLE_AGENT_DIR`, plus
      project-local `.truffle`). `PromptTemplates.load_all` loads user prompts,
      project prompts, and explicit prompt paths in pi's order, with an
      `include_project:` escape hatch for callers that need a trust gate before
      reading project-local instructions. Item 17 is closed.
    - [x] **Slash command registry and expansion into prompts/actions.**
      `Truffle::SlashCommands::Registry` parses `/name args`, expands prompt
      templates before the provider turn, dispatches handler commands without a
      provider response, exposes pi's built-in command info for UI/help surfaces,
      and suffixes duplicate invocation names like pi extension commands.
18. **Extensions.** A plugin seam so third parties add tools, providers, and
    commands without forking.
    - [x] **Event bus.** `Truffle::EventBus` ports pi's `core/event-bus.ts`: the
      channel-based `emit`/`on`/`clear` pub/sub seam exposed to extensions as
      `pi.events`, with `on` returning an unsubscribe closure, raising handlers
      isolated and logged rather than propagated, snapshot dispatch so handlers may
      (un)subscribe mid-emit, and a `Monitor` for cross-thread use.
    - [x] **Discovery.** `Truffle::Extensions` ports the pure filesystem layer of
      pi's `core/extensions/loader.ts`: `extension_file?`, `read_manifest`,
      `resolve_entries`, and a one-level `discover_in_dir` walk that finds extension
      entry points (direct `.rb` files, subdirectory manifests, `index.rb`) before
      anything is loaded, following symlinks and tolerating broken packages.
    - [x] **Ruby extension loading foundation.** `Extensions.load_file` evaluates
      a discovered `.rb` extension entry with a `truffle` API object, the Ruby
      analogue of pi calling a default extension factory with `ExtensionAPI`.
      Extensions can register tools, slash commands, event handlers, and
      provider configs as data; `load_files` collects per-file errors so one
      broken extension does not stop the rest.
    - [x] **Default extension directories.** `Extensions.load_all` ports pi's
      `discoverAndLoadExtensions` path order for Ruby: project
      `.truffle/extensions`, user `agent_dir/extensions`, then explicit paths.
      Explicit directories resolve as a package/index first and fall back to
      direct discovery; entries are de-duplicated by expanded path before load.
    - [x] **Bind tools and commands into agents.** `Agent` and `Truffle.agent`
      accept loaded extensions from `Extensions.load_file`, `load_files`, or
      `load_all`. Extension tools join the toolbox (application tools override a
      same-name extension tool), extension slash commands join the command
      registry, duplicate command names keep pi's `:1`, `:2` suffixing, and
      `Agent.load` can rebind session-required tools from extensions.
    - [x] **Bind event handlers into agents.** Loaded extension handlers
      registered with `truffle.on(...)` now observe the agent events Truffle
      already emits. Handlers run in extension load order, then registration
      order within each extension; a raising handler is recorded on
      `agent.extension_errors` and does not stop later handlers or the agent run.
    - [x] **Bind OpenAI-compatible provider registrations.** Loaded
      `truffle.register_provider` configs can back `Truffle.provider` and
      `Truffle.agent` when they describe an OpenAI Chat Completions-compatible
      endpoint. Registered `base_url` / `baseUrl`, `api_key` / `apiKey`, default
      `model`, and `models` are honored; later registrations for the same
      provider override defined values; `LoadResult` runtime unregisters are
      respected; and registered model names can infer the provider without
      mutating the global catalog.
    - [x] **Bind provider request headers.** OpenAI-compatible provider
      registrations honor provider-level `headers` and `auth_header` /
      `authHeader`. Header values use the same literal and `$ENV` / `${ENV}`
      interpolation path as api keys; `authHeader` adds a generated bearer token
      after custom headers; `authHeader: false` lets a registration supply its
      own `Authorization`; and caller-supplied `headers:` override registered
      headers per key. Chat and streaming requests share the same provider
      headers.
    - [x] **Bind model-specific provider request headers.** OpenAI-compatible
      extension provider models can declare their own `headers`; Truffle resolves
      those values with the same literal and `$ENV` / `${ENV}` interpolation as
      provider headers, applies the headers for the actual request model, and
      keeps pi's merge order: provider defaults, model headers, then generated
      bearer auth when enabled.
    - [x] **Refresh live provider registration overrides.** An already-built
      agent now observes later OpenAI-compatible `truffle.register_provider`
      overrides before the next provider turn, so event handlers and extension
      slash-command handlers can move the active provider endpoint without
      reloading extensions.
    - [x] **Live provider unregister/revert.** An already-built agent now observes
      later `truffle.unregister_provider` calls before the next provider turn:
      built-in provider names restore the built-in provider with caller overrides,
      while extension-only provider names fail clearly instead of silently reusing
      a stale endpoint.
    - [ ] Bind provider registration reload/unregister into sessions, plus
      non-OpenAI custom APIs, OAuth, and `streamSimple`.
    - [ ] Bound extension runtime context: session/UI actions, model access,
      compaction, project trust, command contexts, and event dispatch from pi's
      `core/extensions/runner.ts`.

## Phase 5: adoption + the CLI

19. **`truffle` binary.** Load a tools file, start an interactive REPL against a
    chosen provider, render the event stream.
    - [x] Argument parser. `Truffle::CLI.parse_args` ports pi's `cli/args.ts`
      `parseArgs`: a pure argv-to-`Args` function with the diagnostics, unknown-flag
      capture, and per-flag quirks the binary will act on. The REPL, help text, and
      acting on the parsed flags are later slices.
    - [x] Help and version text. `Truffle::CLI.help_text` and `version_text` port
      pi's `printHelp`: pure string builders for `--help` and `--version`. The
      options block lists exactly the flags the parser recognizes (a test holds them
      in sync); the environment variables and built-in tool names describe this
      harness's real surface (three providers, six built-in tools). The REPL and
      acting on the parsed flags remain later slices.
    - [x] Binary entry point. The gem ships a `truffle` executable backed by
      `Truffle::CLI.run`, the Ruby counterpart of the top of pi's `main.ts`
      dispatch: it parses argv, surfaces diagnostics, and acts on the terminal
      flags from this slice (`--version`, `--help`), returning an exit
      status from injectable streams so the dispatch is testable offline. The
      interactive REPL and `--export` remain later slices.
    - [x] Model listing. `truffle --list-models [search]` prints the built-in
      model catalog as an aligned offline table, sorted by provider and model,
      with provider, model id, context, max output, reasoning, and image support
      columns.
    - [x] Print-mode text renderer. `Truffle::CLI.render_print_text` ports the
      text branch of pi's `runPrintMode` (`modes/print-mode.ts`): the final
      assistant `Response` of a single-shot run renders each text content block
      on its own line to stdout, while an error or aborted stop reason writes
      `error_message || "Request <reason>"` to stderr and exits 1. Pure over
      injectable streams so it tests offline; the `--print` dispatch that drives
      the agent and feeds it is the next slice.
    - [x] Print-mode dispatch. `Truffle::CLI.run` acts on `--print`/`-p`: it
      builds a provider-backed agent (builtin tools narrowed by `--no-tools`,
      `--tools`, and `--exclude-tools`), assembles prompts the way pi's
      `buildInitialMessage` does (piped stdin and the first message joined,
      remaining messages sent after), captures the final assistant turn through
      the `:agent_end` event using pi's last-assistant-message rule, and renders
      it through `render_print_text`. An unresolvable provider/model fails on
      stderr with exit 1. An injectable `agent_builder:` keeps the dispatch
      offline-testable. RPC mode, sessions, `--continue`/`--resume`,
      extensions, skills, `@file` content and images, and the interactive REPL
      remain later slices.
    - [x] Print-mode JSON output. `truffle --print --mode json` subscribes to
      the agent event stream and writes one newline-delimited JSON object per
      event, with a `type` field plus JSON-safe payload data. `--mode json`
      also triggers the one-shot print path without `--print`, matching pi's
      top-level dispatch. RPC mode is parsed but reports not implemented until a
      real `runRpcMode` port lands. Session headers and the RPC runtime remain
      later slices.
20. **`truffle init` + config.** Create a project config dir, a memory file, and
    on-disk state. Document the layout.
21. **Migrations.** A versioned migration path for a host project's on-disk state
    (sessions, memory) so upgrades are safe.

## Guiding constraints

- Faithful to pi: read pi's real source before each slice; match its shapes.
- From scratch: no runtime gem dependencies; every provider hand-written.
- Readable: the core loop stays small enough to read in one sitting.
- Tested: every increment lands with tests; the offline suite stays offline.
