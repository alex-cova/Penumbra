# Agent harness plan (`AgentKit` + Umbra integration)

A coding agent harness written in pure Swift (Foundation only, no third-party SDK), starting with OpenAI, for Umbra.

Status: planned, nothing built yet. Decisions below were settled on 2026-10-01; the rest was checked against the code the same day.

## Terms

- **Turn**: one model request and its streamed response.
- **Run**: everything one user message sets off, turns and tool calls, until a turn ends without tool calls, the user stops it, or a guardrail does. Checkpoints, Revert and the iteration cap are per run.
- **Session**: one conversation (many runs) in one window, persisted per project.

## Decisions

| Decision | Choice | Consequence |
|---|---|---|
| App Store | `AgentKit` is a separate package with no `Penumbra` dependency. Shell execution lives in `Example/Umbra` behind explicit user consent, like Gradle. | `Penumbra` and `EditorIntelligence` stay App Store-safe (see root `CLAUDE.md`). |
| API | Both OpenAI **Responses** (`/v1/responses`) and **Chat Completions** (`/v1/chat/completions`), as separate `LLMClient` conformances. | The loop never sees which API is in use. Chat Completions also covers Azure, Ollama, LM Studio. |
| Edit format | Both exact-match replace (`edit_file`, default) and a unified-diff patch tool. | Two edit tools; patch is atomic across files. |
| Autonomy default | Auto-accept edits (one undo group, checkpointed); approve every command. | A checkpoint must exist before the first edit; the path jail must be strict. |

## What exists today

- `Sources/EditorIntelligence/AI/`: `AITextModel.generate(prompt:) -> String`, `AICompletionProvider`, `AIHoverProvider`. One-shot text in/out, no messages, tools or streaming. Not extended; the agent gets its own layer.
- No OpenAI client, API key storage or Keychain code anywhere.
- `GradleCommandRunner` (gated by `GradleTrustStore`, streaming, timeout, cancel) and `JDKLocator` live in `Sources/JavaIntelligence` and already use `Process`; `IDETerminalPanel` uses SwiftTerm.
- `IDEWorkspaceEditApplier` applies a `WorkspaceEdit`: open files through `TextEditApplicator` (one undo group, left dirty), closed files rewritten on disk (atomic, UTF-8 only, permissions kept, resolved path must be under the project root). Gaps for the agent:
  - `WorkspaceEdit` has text edits, renames and deletions (to the Trash) but **no file creation**.
  - Only closed files are jail-checked; an open file outside the project is still edited.
- Diagnostics: `IDEProblemsStore` holds editor, compiler, inspection and build diagnostics, but only for open files and the last Gradle build. `JavaCompilerDiagnosticsService.diagnostics(for:)` returns the *previous* result and compiles in the background (keyed by a hash of the text); `compileNow` skips the idle wait but returns nothing.
- Search: `ProjectSearchEngine` (`Sources/EditorIntelligence/Search`) with `FileEnumerationPolicy` (fixed ignore list, hidden files skipped, 2 MB cap, binaries by extension). `.gitignore` is not read. `IDEPaletteFileIndexer.index` is an in-memory snapshot of the project's files.
- Git: `GitRepository` has `status()`, per-path `workingTreeDiff` / `stagedDiff` / `unstagedDiff`, `log`. No whole-tree diff, and it reads disk, so dirty buffers are invisible to it.
- Java navigation: `JavaGoToDefinitionProvider`, `JavaFindUsagesProvider`, `JavaStructureProvider` (`NavigationProvider` actors fed a `NavigationContext`).
- UI: `IDEWorkspaceEditPreviewSheet`, the `Diff/` viewer (an `IDEDiffRequest` can compare fixed text), `IDENotificationCenter`, tool windows (`IDEToolWindow`, leading and trailing placements; the Gradle sidebar is trailing), per-window `IDEWorkspace` with `teardown()`, `IDERetentionGuardTests` / `IDEHostedWindowRetentionTests`.
- `Example/Resources/Umbra.entitlements` is empty (app is not sandboxed today).

## Components

### 1. `AgentKit` package (new)

`Packages/AgentKit`, its own package like `Packages/GitIntelligence`: tools version 6.0, Swift 6 language mode, macOS 14, no dependencies (Foundation only: `URLSession`, `Codable`). Only Umbra and test/eval targets depend on it; `Penumbra`, `EditorIntelligence` and `JavaIntelligence` never do. It makes network calls only when the host starts a run.

| `AgentKit` (pure, unit-tested) | `Example/Umbra` (wiring) |
|---|---|
| `LLMClient`, both OpenAI clients, SSE reader, message model | Settings pane, Keychain, panel UI |
| `AgentSession` loop, guardrails, session file format | `IDEWorkspace+Agent.swift`, one session per window |
| `Tool` protocol, schema builder, `AgentWorkspace` protocol | `IDEAgentWorkspace`: live buffers, `IDEWorkspaceEditApplier`, `ProjectSearchEngine` |
| Generic tools: `read_file`, `list_dir`, `glob`, `grep`, `edit_file`, `write_file`, `apply_patch`, `todo`, `ask_user` | IDE tools: `run_command`, `gradle` / `run_tests`, `diagnostics`, navigation, git |
| `PathJail`, exact-match edit matcher, unified-diff parser, output truncation, checkpoints | Approval UI, command runner (`Process`) |
| `DiskAgentWorkspace` for tests and the eval CLI | |

`AgentWorkspace` is the seam: a file's current text (buffer or disk), apply edits, create and delete files, list, search. Generic tools only see it, so they are tested against temp directories, and Umbra alone decides that an open file means its buffer.

**LLM layer**

- **`LLMClient`**: `stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error>`. Events: text delta, reasoning-summary delta, tool-call start (id, name) / arguments delta / end, opaque item, usage, finish (completed, tool calls, length, content filter).
- **Message model**: system / user / assistant / tool-call / tool-output items with call ids and per-turn usage, plus **opaque provider items** (Responses reasoning items with `encrypted_content`). Opaque items are replayed only to the client that produced them and dropped when the user switches API flavor or model.
- **Tool schemas** are written once and rendered per API (Responses: flat `{type, name, parameters, strict}`; Chat Completions: nested under `function`). Strict mode where the endpoint supports it, so schemas list every property in `required`, set `additionalProperties: false`, and type optional parameters as nullable.
- **SSE reader** (shared) over `URLSession.bytes(for:).lines`: each `data:` line is one event (OpenAI puts an event's JSON on one line), `:` keep-alives are skipped, `[DONE]` ends the stream. Don't depend on blank-line event boundaries; `AsyncLineSequence` doesn't deliver empty lines. Request timeout long enough for slow reasoning starts (≥ 300 s).
- **Errors**: retry 429, 5xx and dropped connections with backoff, honoring `Retry-After`. A retry discards the partial turn and resends it; tools only run after a turn ends, so that is safe. 401 → "check the API key"; a context-length 400 → compact once and retry; other 4xx are shown as-is. Cancelling the stream cancels the bytes task, which closes the connection.
- **`OpenAIResponsesClient`**: stateless. The full input every turn, `store: false`, `include: ["reasoning.encrypted_content"]` for reasoning models, no `previous_response_id`. The session owns history anyway (compaction, persistence, Revert, parity with Chat Completions) and nothing is kept on OpenAI's side. Events used: `response.output_item.added` / `.done`, `response.output_text.delta`, `response.function_call_arguments.delta` / `.done`, `response.reasoning_summary_text.delta`, `response.completed` (usage), `response.incomplete`, `response.failed`, `error`; anything else decodes to `.unknown` and is skipped. Tool results go back as `function_call_output` items keyed by `call_id`.
- **`OpenAIChatCompletionsClient`**: tool-call fragments are keyed by `index`, and `id` and `name` arrive only in the first one. Usage needs `stream_options: {"include_usage": true}` and comes in a last chunk with empty `choices`. Compatible servers differ, so each endpoint carries capability flags (strict tools, parallel tool calls, usage in stream); without usage the budget falls back to estimates.
- **Endpoint config**: base URL, extra headers and query items (Azure's `api-key` and `api-version`), model, capability flags.

### 2. Agent loop (`AgentSession`, an actor)

- A run: send, stream, collect tool calls, execute, append outputs, repeat until a turn has no tool calls.
- **Every tool call gets exactly one output**, including denied, failed, timed-out and cancelled calls; both APIs reject a history with an unanswered call. A tool failure is an output the model can act on, never an error that ends the run.
- **Order**: a turn's read-only calls run concurrently; edits, commands and `ask_user` run one at a time in the order the model sent them; outputs go back in call order.
- **Endings**: no tool calls (done); length / incomplete (report, offer Continue); refusal or content filter (report); iteration cap (pause with "Continue", not fail); Stop.
- **Stop** cancels the stream and running tools (killing command process groups), writes "cancelled by user" outputs for pending calls, and leaves the session valid, so the next message continues it.
- **Guardrails**: iteration cap, per-tool timeout; the same call (tool and arguments) a third time in a run gets an output saying so, and a fourth stops the run.
- **State** for the UI: idle, streaming, running tool, awaiting approval, awaiting answer, plus deltas.
- **Persistence**: one JSON file per session under Application Support (`Umbra/Agent/<hash of project root>/<session id>.json`), written after each turn, never holding the API key. Sessions contain file contents, so they stay local, and "Clear History" deletes them.

### 3. Tools

`Tool` protocol: name, description, JSON schema, risk (`read`, `edit`, `command`), `execute(arguments, context) async -> ToolOutput`. The model names files by project-relative path and code by the line numbers it has seen, never by offsets.

| Tool | Notes |
|---|---|
| `read_file` | Numbered lines, capped (about 2,000 lines / 64 KB) with `offset` / `limit` paging. Open files come from the buffer. Records a hash of what the model saw. |
| `list_dir`, `glob` | `glob` filters the `IDEPaletteFileIndexer` snapshot, no disk walk. Same ignore rules as the Explorer. |
| `grep` | `ProjectSearchEngine` with the Find in Files policy; dirty buffers are searched from their text, not disk. Capped, `path:line: text`. |
| `edit_file` | `old_string` → `new_string`, matching exactly once unless `replace_all`; errors say "not found" or "found N times, add context". Refused if the file changed since the model last read it. Line endings are normalized for matching and the file's own are kept. Through `IDEWorkspaceEditApplier`. |
| `write_file` | Create or overwrite; overwriting needs a prior read. Needs file creation added to `WorkspaceEdit` / `IDEWorkspaceEditHost` so the Explorer and watcher treat it like any new file. |
| `apply_patch` | Unified diff, strict parser, errors naming the hunk and the line that didn't match. All-or-nothing: every hunk is checked against the current text, then one `WorkspaceEdit` is applied. Ships after the approval/checkpoint flow is stable. |
| `run_command` | See section 4. Lives in `Example/Umbra`, not `AgentKit`. |
| `gradle` / `run_tests` | `GradleCommandRunner`. Needs the project's Gradle trust **and** approval per call: build scripts are code, so "approve every command" includes Gradle. Output reaches Problems like Build Project (`applyGradleBuildOutput`); the model gets a summary (compiler errors, failed tests with the first lines of each failure), not the log. |
| `diagnostics` | Files the run changed: build a `Document` from the current text and await fresh compiler and inspection results. `JavaCompilerDiagnosticsService` needs an awaitable "diagnostics for this exact text" call for this. Other files: `IDEProblemsStore`. Says so when javac isn't configured (untrusted project, no JDK). |
| `go_to_definition`, `find_usages`, `symbols` | JavaIntelligence providers. Input: path, line and symbol name (the tool finds the column). Output: `path:line: text`, capped. |
| `git_status`, `git_diff` | Read-only `GitRepository`. `git_diff` joins the per-path diffs of `status()` entries, capped, and names dirty buffers it can't see. |
| `ask_user` | Pauses the run until the user answers in the panel. |
| `todo` | Checklist the model keeps; shown at the top of the panel, stored with the session. |

No web fetch or search in v1: it would be an exfiltration path and a second source of injected instructions.

### 4. Safety and permissions

- **Modes.** Default: read-only tools run, edits auto-apply (checkpointed), every command and Gradle call asks. "Plan only" leaves edit and command tools out of the request, so the model doesn't keep trying them. "Approve each edit" shows each edit's diff in its card with Apply / Reject.
- **Path jail** (`PathJail`, checked by every file tool before the applier, since the applier only checks closed files): standardize, resolve symlinks, require the root path plus `/` as prefix (so `/proj2` doesn't pass for `/proj`); a path that doesn't exist yet is checked through its nearest existing ancestor. No writes in `.git/`, `.gradle/` or build outputs (`IDEProjectModel.isBuildOutput`). Reading likely secrets (`.env*`, `*.pem`, `*.key`, `*.p12`, `*.keystore`, `id_*`, `.netrc`; editable list) asks first, since what the agent reads goes to the provider.
- **Checkpoints** (per run). Before a file's first change, record its original text, or that it didn't exist, and after each change the hash of what the agent wrote. A "N files changed" summary opens each file in the diff viewer (original ↔ current, as fixed text).
- **Revert Run.** A file whose text still matches the agent's last write is restored: a buffer in one undo group (so Revert itself can be undone), a closed file by atomic write, a created file to the Trash. A file the user changed afterwards is never overwritten; it is listed with its diff for the user to decide. Checkpoints live in memory for the window's lifetime with a size cap; the oldest runs lose Revert first.
- **Undo.** ⌘Z in a buffer undoes the agent's last edit there (one group per tool call). Closed-file writes are on no undo stack; Revert Run is their only way back.
- **Dirty buffers.** Agent edits leave open files dirty. Before `run_command` or Gradle, save the buffers the agent changed. Buffers with the user's own unsaved changes are named in the approval card, never saved silently.
- **Commands.** The approval card shows the command, working directory and the model's reason: Run, Edit, or Deny (an optional note goes back to the model). Execution:
  - `/bin/zsh -c` (not a login shell) in the project root, stdin from `/dev/null`.
  - A built environment, not the app's: `PATH` with the selected JDK's `bin`, `JAVA_HOME`, `HOME`, `TMPDIR`, `LANG`, `TERM=dumb`, plus user-configured extras.
  - Its own process group, so timeout and Stop kill children too (terminating the shell alone leaves them running).
  - Default timeout 2 minutes, up to 10 if the model asks; output truncated head-and-tail for the model, full log in the card.
  - A deny-list (`sudo`, `rm -rf /`, `git push --force`, …) only adds a warning to the card; approval is the control.
- **Prompt injection.** File contents, command output and diagnostics are untrusted data, wrapped and labeled as such. A tool output never approves another call, and nothing a tool returns can change the mode.
- **Disclosure.** First use says that file contents and command output go to the configured endpoint and needs an explicit OK; App Review expects consent before user data goes to a third-party AI service. Nothing is sent until the user sends a message.
- **If Umbra is sandboxed later**: add `com.apple.security.network.client`; commands inherit the sandbox (the same limits Gradle would hit); the Keychain works unchanged.

### 5. Context management

- **System prompt**, stable for the session: role and rules, tool guidance, project root, build system, JDK, and the root `AGENTS.md` (or `CLAUDE.md` when there is none).
- **Per-message context**, attached to each user message rather than the system prompt so the cached prefix survives: active file, selection, open files, error count.
- **Budget**: context window per model from a small table (overridable in settings). Used tokens = the last turn's reported input tokens plus an estimate (UTF-8 bytes / 4) of what was appended since.
- **Compaction** at about 75% of the window: first replace old tool outputs with one-line stubs (`[read_file Foo.java 1–200, elided]`), oldest first and in one batch, so the cached prefix breaks once instead of every turn; if still over, one summarization request replaces the oldest runs with a summary. The panel keeps showing the full transcript.
- **Large outputs**: every tool caps its output and ends with "N more lines, use `offset`".
- **Prefix caching**: system prompt and tool definitions byte-identical across turns and launches: fixed tool order, `JSONEncoder` with `.sortedKeys` (dictionary order changes between launches). Pass a stable `prompt_cache_key` per session where the endpoint takes one.

### 6. App integration (`Example/Umbra`)

- `IDEAgentPanel`, a tool window (placement under Open items). Transcript, collapsible tool-call cards (edits show their diff, commands their live output), approval and `ask_user` prompts inline, the todo list, Stop, tokens per run (cost where known).
- **Streaming cost**: coalesce deltas (flush about every 50 ms) and re-render only the message being streamed; show it as plain text while streaming and render Markdown when it completes; the transcript list is lazy.
- `IDEWorkspace+Agent.swift`: one `AgentSession` per window. Tools reach the workspace weakly; `teardown()` cancels the run and drops the session (a leaked session keeps the workspace alive; the retention tests cover it).
- Settings pane: API key, API flavor, base URL, model, autonomy mode, iteration cap, secret-file patterns, extra command environment.
- API key in the **Keychain** (`SecItem`, generic password, one per endpoint), never `UserDefaults` or session JSON. An opt-in request log redacts the `Authorization` and `api-key` headers.
- Entry points: "Ask Agent About Selection", "Fix with Agent" in Problems, a command-palette command, and the panel's button in the tool-window stripe.

### 7. Tests and tooling

- `MockLLMClient` replaying scripted event streams: loop, concurrent reads vs serial edits, approval and deny, Stop mid-tool, outputs for every call, iteration cap.
- SSE fixtures for both clients (hand-written from the API docs, later real captures): split chunks, partial JSON arguments, interleaved parallel calls, unknown events, usage-only last chunk, error mid-stream.
- Pure tests: exact-match edit (zero, one, several matches; CRLF), patch parser and atomicity, `PathJail` (symlink escape, `..`, sibling prefix, new file under a symlinked folder), truncation, compaction.
- Checkpoints against `DiskAgentWorkspace`: revert, created-file revert, a file the user changed after the agent.
- Retention: a window with an agent session (idle, mid-run, awaiting approval) deallocates after `teardown()`.
- Optional eval CLI (`Tools/AgentEval`, like `PerfHarness`): scripted tasks against a fixture Gradle project through `DiskAgentWorkspace`, checked by running the project's tests; reports pass rate, turns and tokens.

## Build order

Each step ends usable, with its tests.

1. **`AgentKit` skeleton**: package, `LLMClient`, `LLMEvent`, message model, SSE reader, Responses client, `MockLLMClient`, fixtures. Done when mock and fixture tests pass and an opt-in smoke test streams text with a real key.
2. **Read-only assistant**: loop, `AgentWorkspace` and `IDEAgentWorkspace`, `read_file` / `list_dir` / `glob` / `grep`, `diagnostics` from `IDEProblemsStore`, a minimal panel, Keychain with key and model settings, the disclosure. Done when a question about the project gets an answer citing files, and Stop works mid-stream.
3. **Edits**: `PathJail`, `edit_file`, `write_file` (with file creation in `WorkspaceEdit`), checkpoints, changed-files summary, Revert Run. Done when a multi-file edit reverts cleanly, including a file the user touched in between.
4. **Commands**: `run_command`, `gradle` / `run_tests`, approval card, environment and process groups, fresh compiler results in `diagnostics`. Done when "make this test pass" works end to end on a fixture project.
5. **Second API and patches**: Chat Completions client with capability flags (checked against Ollama), `apply_patch`.
6. **Long sessions**: compaction, persistence and resume, `AGENTS.md`, the full settings pane, plan-only and approve-each-edit modes.
7. **IDE depth**: navigation and git tools, "Fix with Agent" and selection entry points, cost display.

## Open items

- **Panel placement.** Recommended: a trailing tool window like the Gradle sidebar (`IDEToolWindow.Placement.trailingTop`). A chat wants height and stays beside the code; the bottom panel competes with Terminal and Problems, and a left-sidebar tab hides the Explorer.
- **Cost display.** Recommended: tokens always; cost only for models in a small bundled price table (editable), nothing for unknown or local models.
- **Eval CLI.** Recommended: yes, as `Tools/AgentEval` in the root package. It has no command tool; it runs the fixture's tests itself after each task.
- **Command allowlist.** Whether "always allow this exact command in this project" is worth adding once the every-command prompt has been lived with.
- **`.gitignore`.** `grep` and `glob` follow the Explorer's fixed ignore list. Honoring `.gitignore` (`git ls-files` / `check-ignore` through GitIntelligence) would help large repos, and Find in Files too.
