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
   - [x] **Offline model-catalog refresh.** `script/refresh-models` regenerates a
     candidate committed catalog from `models.dev/api.json` with full cost keys
     and no runtime network path.
   - [x] **Provider resolution.** Resolve a bare `model:` string to the right
     provider automatically the way pi's `ai` package does, so the caller need
     not also name the provider. `Models.resolve` ports pi's
     `findExactModelReferenceMatch` (bare id, canonical `provider/id`, dated
     snapshots, case-insensitive, ambiguity rejected); `Truffle.agent` infers the
     provider from `model:` and reduces a `provider/id` reference to the bare wire
     id.
   - [x] **In-process OpenAI-compatible provider registry.** Apps can call
     `Truffle.register_provider` / `unregister_provider` with the same config
     shape extension files use, and `Truffle.provider` / `Truffle.agent` resolve
     those providers without writing a `.truffle/extensions` file.
9. [x] **Structured tool results.** A tool may return a hash/array, serialized
   as JSON for the model; plain strings keep working. `Tool#call` serializes any
   non-String return with `JSON.generate` (Infinity/NaN fall back to `to_s`),
   mirroring pi's `JSON.stringify` of a structured result.
10. **Structured output.** Ask a model for a JSON object matching a declared
    shape, the way pi's `ai` package wires native structured output per provider.
    - [x] **Schema value object.** `Truffle::Schema` is an immutable
      JSON-Schema value object built by a block DSL that mirrors
      `Tool::Builder`'s `param`: object root with `properties`/`required`,
      scalars, nested objects, and arrays with an `items` schema. `#to_h` emits
      the provider-neutral hash; `.from_h` is its JSON-round-trip inverse,
      folding string or symbol keys to the canonical form so equality survives.
      Deeply frozen, usable as a hash key.
    - [x] **Provider seam.** A `schema:` option on the provider request builders,
      wrapped in each API's envelope (OpenAI `response_format.json_schema`,
      Anthropic `output_config.format`, Gemini `generationConfig.responseJsonSchema`
      plus `responseMimeType`). OpenAI drops it for a non-native base URL.
    - [x] **Parsed accessor.** `Response#parsed` lazily `JSON.parse`s the final
      text, with an advisory `Schema#valid?`/`#errors` for callers that validate.
    - [x] **Argument coercion.** `Truffle::SchemaCoercion.coerce` moves a parsed
      value toward its declared JSON-Schema types before validation, porting pi's
      coercion layer (`ai/src/utils/validation.ts`): scalar nudges, nested
      objects, `additionalProperties`, tuple/single arrays, and `allOf`/`anyOf`/
      `oneOf` resolved through the first validating member. Non-mutating.
    - [x] **Short hash for id rewriting.** `Truffle::ShortHash.of` ports pi's
      `shortHash` (`ai/src/utils/hash.ts`) byte for byte, the folding the OpenAI
      Responses provider uses to rewrite foreign tool-call and message ids
      (`fc_#{hash}`, `msg_#{hash}`). UTF-16 code-unit iteration and 32-bit
      `Math.imul`/shift semantics reproduced; verified against pi across 27
      inputs including astral emoji surrogate pairs.
    - [x] **Per-call token-budget math.** `Truffle::TokenBudget` ports pi's
      `simple-options.ts`: `clamp_max_tokens_to_context` fits an output cap inside
      the remaining context window (4096-token safety margin, one-token floor),
      `clamp_reasoning` folds `xhigh` to `high`, and
      `adjust_max_tokens_for_thinking` splits a cap into a thinking budget plus a
      1024-token visible-answer floor. Pure and provider-agnostic: the caller
      passes the context estimate as an integer and a provider option builder
      consumes the result when translating a reasoning level into API parameters.
    - [x] **Non-vision image downgrade.** `Truffle::MessageTransform.
      downgrade_unsupported_images` ports the image pass of pi's
      `transform-messages.ts`: for a model without an image input modality, user
      and tool-result image blocks become a placeholder text block, consecutive
      images collapsing to one. Built-in catalog models and registered model
      definitions retain their input capability record on `Agent#model_spec`;
      buffered and streaming provider requests apply the transform without
      mutating session history. Registered models that omit `input` remain
      conservative and pass images through. The rest of
      `transformMessages` (cross-model thinking, tool-call-id normalization,
      synthetic tool results) waits on assistant-message provider/model metadata
      the flat `Message` does not yet carry.
    - [x] **General path helpers.** `Truffle::Paths` ports the classification and
      display half of pi's `paths.ts`: `local_path?` (local path versus a remote
      `npm:`/`git:`/`github:`/`http:`/`https:`/`ssh:` source, with `file:` local),
      `canonicalize` (realpath through symlinks, input as fallback on a missing
      path), `cwd_relative_path` (relative when inside cwd, `.` for cwd itself,
      `nil` when it escapes), and `format_relative_to_cwd_or_absolute` (relative
      when inside cwd, absolute otherwise, forward-slashed). Resolution uses
      `File.expand_path` with `Pathname#relative_path_from`; the tool-input
      resolver (unicode fold, `@`-strip, literal `~user`) stays in
      `Truffle::Tools::Path`, and `markPathIgnoredByCloudSync` (OS xattr) is out
      of scope.
    - [x] **ANSI stripping.** `Truffle::Ansi.strip` ports pi's `stripAnsi`
      (the ansi-regex/strip-ansi code from `ansi.ts`): removes OSC and CSI/C1
      escape sequences with the same regex, a fast path that returns the input
      object when it has no ESC/CSI introducer, and a `TypeError` guard on a
      non-string. Wiring it plus a binary-output sanitizer into the bash tool's
      output cleaning is a follow-up.

## Phase 3: the coding-agent surface

Match `packages/coding-agent`: the tools and runtime that make an actual agent.

10. **Built-in tools.** bash, read, write, edit, find, grep, ls, written from
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
    - [x] **ls.** `Truffle::Tools.ls` ports pi's `ls.ts` execute path: an optional
      `path` (default `.`) and an optional `limit` (default 500). Entries are read
      with `Dir.children` (dotfiles included, `.`/`..` excluded), sorted
      case-insensitively, and each directory gets a `/` suffix; entries that fail
      to stat (a dangling symlink) are skipped. The limit is passed through
      without a floor, matching pi, so `limit=0` yields an empty listing; an empty
      result reports `(empty directory)`. The entry limit and the 50KB byte
      ceiling produce pi's bracketed notices. pi's TUI `renderCall`/`renderResult`
      is out of scope.
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
    - [x] **Pluggable store seam.** `Session` talks to persistence through a small
      interface (`#read`, `#write`, `#append`, `#exists?`, `#path`), so a host can
      back conversations with a database or anything else without Truffle taking a
      dependency. `Session::FileStore` is the default conformer and keeps the JSONL
      format, interrupted-line tolerance, and v1/v2 migration as its own concern;
      the `#append` contract holds the store consistent across its block, keeping
      the flock/leaf-refresh semantics in the file store. `Session.start(store:)` /
      `Session.open(store)` are the store-generic entry points, while `create`,
      `load`, `session.file`, and `Agent.load` are unchanged. See
      `examples/custom_session_store.rb`.
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
      - [x] **Changelog data layer.** `Truffle::Changelog` ports pi's
        `changelog.ts` parsing (`parse`, `compare_versions`, `new_entries`), the
        entries the `changelog` built-in command renders. pi's monorepo-specific
        link rewriter is out of scope; wiring the parser into the handler remains.
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
    - [x] **Resume sessions through registered providers.** `Agent.load` now uses
      the provider recorded in a session's latest `model_change` entry when the
      caller omits `provider:`. It resolves that provider through extensions or
      the in-process registry, while an explicit provider still wins.
    - [ ] Bind provider registration reload/unregister into active session state,
      plus non-OpenAI custom APIs, OAuth, and `streamSimple`.
      - [x] **Provider runtime collection facade.** `Truffle.providers` now
        exposes a small pi-style provider runtime view for Ruby hosts:
        process-local providers can be listed, upserted, deleted, and resolved
        to model references; loaded extension provider registrations can be
        inspected through the same facade. Unsupported non-OpenAI APIs remain
        metadata-only until a later request-transport slice binds them.
    - [ ] Bound extension runtime context: session/UI actions, model access,
      compaction, project trust, command contexts, and event dispatch from pi's
      `core/extensions/runner.ts`.
      - [x] **Event handler context dispatch.** Agent-bound extension event
        handlers now receive a Ruby runtime context as their second argument,
        exposing the active agent, session, provider, model id, model metadata,
        usage, system prompt, cwd, mode, and abort signal. UI, project trust,
        pending-message, idle, and context-usage helpers are present with
        conservative values until the richer runtime slices land.
      - [x] **Command handler context dispatch.** Extension slash-command
        handlers that accept a second argument now receive a Ruby command
        context with the same runtime fields plus command metadata: the command
        object, raw argument string, and parsed arguments. Session/UI command
        actions from pi's full `ExtensionCommandContext` remain later work.
      - [x] **Command context runtime actions.** Command contexts now bind the
        useful actions Truffle can support in the current line-oriented runtime:
        read/set the session display name, trigger manual compaction through the
        same session-backed compactor as the agent loop, read the effective
        system prompt, and inspect the model catalog. Missing session state
        raises clearly instead of pretending a TUI/session action succeeded.
      - [x] **Provider registry context access.** Extension event and command
        contexts expose `model_registry` (plus `provider_registry` /
        `providers` aliases) backed by the active agent's provider runtime
        collection. Handlers can inspect extension-registered providers and
        resolve model references, including command-time provider registrations,
        without mutating process-global provider state.
      - [x] **Context cancellation helpers.** Extension event and command
        contexts expose `abort`, `has_ui?`, `has_pending_messages?`,
        `get_context_usage`, and `system_prompt_text` helpers. `abort` trips the
        active run's `AbortSignal` and fails clearly when no run signal is
        available; shutdown, TUI overlays, and session-switch actions remain
        future interactive-runtime work.

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
    - [x] Image MIME sniffing. `Truffle::Mime.detect_supported_image_mime_type`
      and its `_from_file` variant port pi's coding-agent `utils/mime.ts`: pure
      magic-byte detection for JPEG, PNG, GIF, WEBP, and BMP that rejects a
      lossless JPEG and an animated PNG, reading raw bytes from a binary String
      with no image library pulled in.
    - [x] Unicode surrogate sanitization. `Truffle::UnicodeSanitizer.sanitize_surrogates`
      ports pi's `utils/sanitize-unicode.ts`: it strips lone surrogate byte
      sequences (`\xED[\xA0-\xBF][\x80-\xBF]`) so text serializes into a provider
      request body without JSON errors, while leaving valid characters (astral
      emoji and the adjacent U+D000-U+D7FF range) untouched and returning a clean
      string unchanged. OpenAI, Anthropic, and Gemini serializers now run outbound
      system, user, assistant, thinking, and tool-result text through it at the
      provider boundary.
    - [x] JSON repair for malformed model output. `Truffle::JsonRepair.repair`
      and `.parse` port the dependency-free half of pi's `utils/json-parse.ts`
      (`repairJson`, `parseJsonWithRepair`): inside string literals, raw control
      characters are escaped and a backslash before an invalid escape is doubled,
      so a model's tool-call arguments parse instead of crashing. `.parse` repairs
      every input before parsing, so a lenient stdlib json version cannot silently
      drop an invalid escape: correctness does not depend on the installed json
      gem's strictness. OpenAI, Anthropic, and Gemini final tool-call deserializers now run
      string-shaped arguments through `Providers.parse_tool_arguments`; unrepaired
      JSON still lands under `_raw`.
    - [x] Streaming partial-JSON completer. `Truffle::PartialJson.parse` is a
      from-scratch port of the `partial-json` package (0.1.7): a recursive-descent
      parser that returns as much structure as it can from a truncated document,
      gated by an `Allow` bitmask. `Truffle::PartialJson.parse_streaming` layers
      the `JsonRepair` complete-document path over it and always returns an object,
      porting pi's `parseStreamingJson` so in-flight tool-call arguments are usable
      before the closing token arrives. Faithfulness verified against the reference
      package across ~600 differential inputs. OpenAI and Anthropic streaming
      accumulators now use it for partial tool-call previews, and use
      `Providers.parse_tool_arguments` for completed streaming tool arguments.
    - [x] Print-mode text `@file` input. Text file arguments are resolved through
      the same path normalizer as the file tools, skipped when empty, wrapped as
      pi's `<file name="absolute/path">` blocks, and inserted into the initial
      prompt after piped stdin and before the first CLI message.
    - [x] Print-mode image `@file` input. Supported image files are resolved
      through the same path normalizer, attached to the first model turn as
      `Truffle::Content::Image` blocks, and represented in text with an empty
      `<file name="absolute/path"></file>` marker for filename context. The slice
      does not resize images or add image-processing dependencies.
      `Truffle::Content::Image.from_file` and `.from_bytes` expose the same
      conversion for app code.
    - [x] Agent-level streaming. `Agent#run_stream` uses provider `#chat_stream`
      inside the same multi-turn loop as `#run`, yielding normalized
      `StreamEvent`s for text/thinking/tool-call deltas while preserving tool
      dispatch, abort, retry, compaction, usage accounting, and the final return
      value.
    - [x] **TTY REPL text streaming.** Interactive runs now drive
      `Agent#run_stream` when stdout is a terminal and the provider implements
      streaming, writing and flushing text deltas as they arrive without
      duplicating the final response. Redirected output keeps the buffered path.
      The terminal event-rendering slice below extends this path.
    - [x] **TTY REPL text-block boundaries.** Streaming output honors
      `text_start` events and writes one newline between non-empty text blocks,
      matching the buffered renderer instead of concatenating separate assistant
      content blocks.
    - [x] **Terminal event rendering.** One line-oriented renderer now drives
      terminal REPL turns and the final prompt in print mode. Assistant text
      streams to stdout; thinking, tool calls/results, retries, and compaction
      status go to stderr; `--no-stream` keeps a buffered path. Ctrl-C aborts
      the current request through `AbortSignal` and returns an interactive run
      to its prompt. Redirected text and newline-delimited JSON output remain
      unchanged.
    - [x] **Initial interactive REPL.** A bare `truffle` now starts a
      line-oriented terminal loop over one long-lived agent. It processes initial
      CLI messages first, reads user turns until EOF or `/exit`, renders assistant
      text through the same final-turn rules as print mode, keeps provider/model
      and builtin-tool flags wired through the shared CLI agent builder, and is
      fully testable with injected streams. Pi's richer TUI and RPC runtime remain
      later slices.
    - [x] **CLI session continue.** `truffle --continue` loads the most recent
      session for the current project and works in both print mode and the
      line-oriented REPL. `--session <path|id>` resolves a specific session file
      or unique project session reference. The richer TUI picker remains a later
      CLI slice.
    - [x] **Default REPL session persistence.** Fresh interactive CLI runs now
      create a project session by default, record the active model and enabled
      builtin tool names, and mirror turns through the session-backed agent path.
      `--no-session` keeps the loop ephemeral; fresh print mode remains
      sessionless.
    - [x] **CLI system prompt wiring.** Fresh and resumed CLI agents now
      regenerate the pi-style system prompt from the same shared builder used by
      the library. `--system-prompt`, repeated `--append-system-prompt`, enabled
      builtin tool descriptions, and AGENTS/CLAUDE context files are included;
      `--no-context-files` keeps project memory out.
    - [x] **CLI session-id creation.** Fresh interactive CLI runs honor
      `--session-id`: an exact existing project session id reopens that session,
      and a missing id creates the new session under that id. Invalid ids and
      conflicting resume flags fail before the provider is built.
    - [x] **CLI session fork.** `truffle --fork <path|id>` creates a new session
      in the current project from an existing session file or local session
      reference, records the source file as `parent_session`, preserves the
      source tool names for resume rebinding, and loads the REPL from that fork.
      `--session-id` can name the fork target when the id is not already in use.
    - [x] **CLI resume picker.** `truffle --resume` shows a numbered,
      line-oriented picker over current-project sessions before building the
      agent. A selection flows through the existing `--session` load path; blank
      input or `q` exits without a provider call. Pi's full TUI selector remains
      part of the richer TUI work.
    - [x] **Cross-project session lookup.** `Session.list_all` scans every
      per-project session directory under the agent sessions root, and
      `--session <id>` / `--fork <id>` now resolve a unique exact or prefix match
      from the current project first and then from all projects. Direct file
      paths still win before ID lookup.
    - [x] **CLI session display name.** `truffle --name <name>` now appends a
      pi-compatible `session_info` entry to the active session before runtime
      provider/model validation, trims edge whitespace, normalizes newlines to
      spaces, and rejects whitespace-only names without changing the session.
20. **`truffle init` + config.** Create a project config dir, a memory file, and
    on-disk state. Document the layout.
    - [x] **Project initializer.** `truffle init` creates `.truffle/` with
      `settings.json`, `prompts/`, `extensions/`, `skills/`, and `sessions/`,
      plus an `AGENTS.md` project memory file when absent. It is idempotent and
      never overwrites existing project files.
    - [x] **Default session directory.** `Config.default_session_dir(cwd:)` puts a
      session's JSONL under `~/.truffle/agent/sessions/--<encoded-cwd>--/`,
      encoding the cwd the way pi does so two projects never collide.
      `Session.create` and `Agent#dump` default `dir:` to it, so a caller gets
      per-project session history without naming a directory.
    - [x] **Session discovery.** `Session.most_recent(cwd:)` and
      `Session.list(cwd:)` read the per-project directory back to choose a session
      to resume, newest-first, filtered by recorded cwd; `Session.read_header`
      reads a header without loading the conversation. Port of pi's
      findMostRecentSession.
    - [x] **Session cwd validation.** `Truffle::SessionCwd` reports when a
      session's recorded working directory no longer exists so a resume can warn
      and fall back to the current directory. `missing_issue` returns an issue
      (nil when there is no session file, no recorded cwd, or the directory is
      present), `format_error` / `format_prompt` build the messages, and
      `assert_exists` raises `SessionCwd::MissingError`. Port of pi's
      core/session-cwd.ts, taking the cwd and file as values rather than pi's
      getter-object.
    - [x] **Project settings load.** `Truffle::Settings.load_project` reads
      `.truffle/settings.json` into a read-only runtime settings object, mapping
      pi-style `defaultProvider` / `defaultModel`, `compaction`, and `retry`
      values onto the options Truffle already understands. `Truffle.agent`
      applies those project defaults only when the caller leaves the matching
      option unset.
21. **Migrations.** A versioned migration path for a host project's on-disk state
    (sessions, memory) so upgrades are safe.
    - [x] **Project settings version migration.** `Truffle::Migrations.run_project`
      provides the first project-local migration runner, grounded in pi's
      idempotent startup migrations. `truffle init` runs it before scaffolding,
      stamping existing unversioned `.truffle/settings.json` objects with the
      current version while preserving other keys; malformed or newer settings
      are left untouched with a warning.
    - [x] **Legacy root session migration.** `Truffle::Migrations.run_agent`
      ports pi's `migrateSessionsFromAgentRoot`: JSONL sessions found directly
      under the agent directory are moved into the correct per-project session
      directory based on their header `cwd`. Malformed files and existing targets
      are skipped, and `truffle init` runs the migration with the project
      migration pass.
    - [x] **Legacy commands directory migration.** `Truffle::Migrations` ports pi's
      `migrateCommandsToPrompts`: project `.truffle/commands/` and global
      agent-dir `commands/` are renamed to `prompts/` only when a `prompts/`
      directory does not already exist. `truffle init` runs this before it creates
      missing project directories so legacy prompts are not stranded.

## Guiding constraints

- Faithful to pi: read pi's real source before each slice; match its shapes.
- From scratch: no runtime gem dependencies; every provider hand-written.
- Readable: the core loop stays small enough to read in one sitting.
- Tested: every increment lands with tests; the offline suite stays offline.
