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
    - [ ] Branch-summary entries, the deferred-first-flush optimization, and
      v1/v2 file migration.
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
      `_prepareRetry`. Follow-up: honor a provider `Retry-After` header once the
      providers parse it onto the response.
14. [x] **Tool middleware.** before/after hooks around tool execution (logging,
    auth, rate limiting) without changing tool definitions. `Agent.new` takes
    `before_tool_call:` (veto a call with `{ block: true, reason: }`) and
    `after_tool_call:` (override the result with `{ result: }`), ported from pi's
    `beforeToolCall` / `afterToolCall`. The before hook runs after the tool
    resolves; the after hook runs on an executed result; an unknown tool skips
    both; a raising hook becomes an error result. Narrowed to this port's
    single-string tool result (no structured content/details/isError/terminate).
15. **Parallel tool dispatch.** Run independent tool calls in one turn
    concurrently while preserving result ordering in the history.

## Phase 4: self-extension (skills, commands, extensions)

16. **Skills.** A skill is a folder with a manifest and instructions, loadable at
    runtime, the way pi loads skills.
17. **Commands.** User-invocable commands that expand into prompts/actions.
18. **Extensions.** A plugin seam so third parties add tools, providers, and
    commands without forking.

## Phase 5: adoption + the CLI

19. **`truffle` binary.** Load a tools file, start an interactive REPL against a
    chosen provider, render the event stream.
20. **`truffle init` + config.** Create a project config dir, a memory file, and
    on-disk state. Document the layout.
21. **Migrations.** A versioned migration path for a host project's on-disk state
    (sessions, memory) so upgrades are safe.

## Guiding constraints

- Faithful to pi: read pi's real source before each slice; match its shapes.
- From scratch: no runtime gem dependencies; every provider hand-written.
- Readable: the core loop stays small enough to read in one sitting.
- Tested: every increment lands with tests; the offline suite stays offline.
