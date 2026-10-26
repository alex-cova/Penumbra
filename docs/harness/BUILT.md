# Agent harness: what was built, and why

Record of the 2026-10-22 plan for closing the gap with opencode. Phases 1 to 9 are built; this file keeps the design, the differences from the design, and the measurements behind the decisions. It is no longer a plan. What is still missing is in `README.md` and `agent-harness-1.md` to `agent-harness-7.md` in this folder. Moved here from `docs/AGENT_HARNESS_PLAN.md` on 2026-10-26.

Written 2026-10-22 after reading opencode's `packages/core/src` (`session/runner/step.ts`, `tool/plugin/subagent.ts`, `plugin/tool-input-repair.ts`, `model-retry.ts`, `tool/plugin/webfetch.ts`, `mcp/`) against `AgentSession.swift`, `CheckpointLog.swift`, `RetryPolicy.swift` and `ToolArguments`. Already done and not repeated here: cut-off continuation, output budget, saved tool output, crash-safe runs, instruction-drift notes, compaction, permissions, plan mode, rewind/fork, stop gate.

Not planned in this round: a durable SQLite inbox, image pruning (AI mode is text-only), a plugin system, LLM-written chat titles, user-configurable tool hooks. Hooks, image input and plugin bundles are now proposed, pending a decision, in `agent-harness-3.md`, `agent-harness-4.md` and `agent-harness-7.md`.

Rules for every phase: AgentKit stays Foundation-only and never spawns a process or touches the disk (hosts implement a protocol); network features are opt-in and user-initiated; each change lands with tests in `Packages/AgentKit/Tests` (or `IDEAgent*Tests` for Umbra code); anything that changes model behaviour is measured with `swift run AgentEval run …` at 5+ trials before and after, never judged on one run.

## Order

| # | Phase | Size | Why first |
|---|---|---|---|
| 1 | Retry policy (done 2026-10-22) | S | Found a real bug: `Retry-After` is clamped to 30 s |
| 2 | Tolerant tool arguments (done 2026-10-22, not yet measured with AgentEval) | S | Helps the local models the eval work targets |
| 3 | Track files changed by commands (done 2026-10-22) | M | Revert Run is silently incomplete today |
| 4 | Start read tools during the stream (skipped 2026-10-22: measured, not worth it) | M | Latency; gate on a measurement |
| 5 | General and background subagents (done 2026-10-22) | L | Biggest capability gap after MCP |
| 6 | `web_fetch` (done 2026-10-22) | M | Reading docs without leaving the agent |
| 7 | MCP client (stdio, tools only) (done 2026-10-22) | L | Ecosystem access |
| 8 | Problems after an edit (done 2026-10-22) | S | Beyond parity; fits an IDE |

1 and 2 are independent and can go in either order. 3 before 5, because a child that edits files needs 3's checkpoint plumbing. 7 needs `ToolDefinition` to carry a raw schema (done inside 7).

## 1. Retry policy

**Built.** `maxRetries` 8, 2 s to 20 s backoff, `maxServerDelay` 300 s, `maxTimeoutRetries` 3; new `AgentEvent.retryScheduled`; Umbra shows the wait in the status line (`IDEAgentToolSummary.retryStatus`). The plan's "Retrying in Ns row" turned out to be a status line, since the transcript had no retry display at all.

Today: `RetryPolicy.default` is 4 retries, 1 s base, 30 s cap, and `Retry-After` is clamped by `min(serverDelay, maxDelay)`. A 429 asking for 60 s is retried after 30 s and fails again, so a rate-limited run ends in about a minute. opencode retries 10 times (2, 4, 8, then 10 s, jittered) and honours `Retry-After` up to 15 minutes.

- `LLM/RetryPolicy.swift`: `maxRetries` 8, `baseDelay` 2, `maxDelay` 20 for backoff; a server-supplied delay is honoured up to a separate `maxServerDelay` (default 300 s). Timeouts (`URLError.timedOut`) retry at most 3 times.
- Emit the delay in `.retrying(attempt:after:)` (already there); check that the transcript shows a "Retrying in Ns" row and add one if it does not (`IDEAgentTranscript`).
- Tests: extend `ProviderTests` with a table of (error, attempt) to delay; a `Retry-After: 120` case; the timeout cap.
- Done when: the table tests pass and a stubbed 429 with `Retry-After: 45` waits 45 s (virtual clock or injected sleeper).

## 2. Tolerant tool arguments

**Built, with one change from the plan:** a lone string is not wrapped into a one-item list. The existing `todo` test caught it: `"not a list"` became a checklist item. Only the unambiguous repairs ship. **Still to do:** the AgentEval before/after measurement below needs a local model and was not run.

opencode repairs `"20"` to `20`, `"false"` to `false`, a stringified array or object, a single item for an array, and `null` or `{}` for an optional field. `ToolArguments` rejects all of these, and the accessors already know the type each caller wants, so no schema is needed.

- `Tools/AgentTool.swift` (`ToolArguments`): `optionalInt` accepts a string that parses to an integer; `optionalBool` accepts `"true"`/`"false"`; `optionalStringArray` accepts a JSON-array string and wraps a lone string; `.object([:])` counts as absent for scalar parameters. `init(json:)` unwraps a double-encoded root (a JSON string holding an object).
- Never repair silently into something ambiguous: `"abc"` for an integer still errors with the existing message.
- Tests: `ToolArgumentsTests` (new), one case per rule plus the negative cases.
- Measure: `AgentEval` with the Ollama and MLX models that showed unreadable or invalid calls, 5+ trials, before and after. Report the count of `invalid arguments` outputs, not only pass rate.

## 3. Track files changed by commands

**Built.** Differences from the design below: (a) the seam also has `text(of:at:)` returning `.text/.unavailable/.absent`, and the diff carries an `omitted` count; (b) `CheckpointLog` learned deletions (`isDeletion`, `didDelete`), which the plan had not covered; (c) a file is recorded only if the snapshot's text equals the disk text, which keeps line-ending and LFS filters from producing a bogus revert; (d) `IDEAgentFileClaims` is **not** extended yet; (e) the 50,000-file rule became "a capture over 4 s turns it off for the chat". Measured: 30-40 ms per capture at 20,000 files. `GitRunner` takes environment variables, so `GIT_INDEX_FILE` worked as hoped. Still open: repositories whose `.gitattributes` rewrites content (the files are named, not revertable); a hash-object based capture would fix that if it matters.

Gap: `CheckpointLog` records only `edit_file`, `write_file` and `apply_patch`. A `run_command` that runs `sed -i`, a generator or a formatter changes files that Revert Run and Rewind cannot undo, and `IDEAgentFileClaims` does not see them either. opencode snapshots the git tree around each step.

Design: a git tree hash before and after each command-risk call, diffed.

- AgentKit gets a seam, no git knowledge: `protocol WorkspaceSnapshotter: Sendable { func capture() async -> SnapshotToken?; func changes(from: SnapshotToken, to: SnapshotToken) async -> [SnapshotChange]; func text(of path: String, at: SnapshotToken) async -> String? }`, and `AgentConfiguration.snapshotter` (nil by default).
- `AgentSession.runBatch`: for a `.command` call, after approval and before the run, `capture()`; after it, `capture()` again and `changes`. For each changed UTF-8 text file under the size cap that the run has not recorded yet: `checkpoints.willChange(run:path:original:)` with the "before" text (`nil` for a created file), then `didChange(run:path:written:)` with the "after" text. A path already recorded keeps its original and only gets a new written hash. Binary or oversize files are counted and named in the tool output ("2 binary files changed; not revertable"), never silently skipped.
- Capture after approval, not while the card is open: the user may edit during that time and the command would be blamed for it.
- Umbra implements `GitTreeSnapshotter` (`Umbra/Sources/Umbra/Agent/IDEAgentSnapshots.swift`) over `GitIntelligence`'s `GitRunner`, which already takes environment variables: copy `.git/index` to a temp file, set `GIT_INDEX_FILE`, run `git add -A` then `git write-tree`. This respects `.gitignore`, so build output is excluded, and the stat cache in the copied index keeps it fast. File contents come from `git cat-file blob <tree>:<path>`; the diff from `git diff-tree -r --name-status`. The temp index is deleted afterwards and the user's index is never touched. Verify first that `GitRunner` can set `GIT_INDEX_FILE` and that blobs written by `git add` into the real object database are acceptable (they are unreachable objects and `git gc` collects them); if not, use a throwaway `GIT_OBJECT_DIRECTORY` with the real one as an alternate.
- Bounds (performance rules apply: this is the agent path, not typing, but it still must not scale with history): skip when the repository lists more than 50,000 tracked files or a capture takes over 2 s, and say once per run "commands are not tracked in this repository". Outside a git repository there is no snapshotter and behaviour is unchanged.
- `IDEAgentFileClaims`: a command's changed paths are claimed after the fact, so a second chat editing them is warned. Commands are still not blocked up front.
- Tests: `CommandSnapshotTests` with a fake snapshotter (changed, created, deleted, binary, already-recorded file, snapshot failure fails open); `IDEAgentSnapshotTests` on a temp git repo (including one with a dirty index that must stay untouched); extend `IDEAgentRevertAfterRelaunchTests` so a command-made change survives a relaunch.
- Done when: `run_command "sed -i '' s/a/b/ F"` then Revert Run restores F, a file the user edited afterwards is reported as a conflict, and a 20,000-file repo captures in well under a second (record the number here).

## 4. Start read tools during the stream

**Skipped after measuring (2026-10-22).** Real tool times in this repository (about 20,000 files, warm): `read_file` and `list_dir` 1-2 ms, `glob` 0.1 s, `grep` 0.2-0.8 s. An early start can only overlap a tool with the rest of the model's stream, which is the time the later calls take to write (roughly 0.5-2 s). So the best case is a few tenths of a second on a multi-call turn that contains a grep, against model turns of several seconds; two parallel `explore` calls would save about 2 s of 30 s or more. That does not pay for restructuring `runBatch` and adding cancellation paths around retries, Stop and unfinished calls. Revisit only if tools get slower (an MCP or network read tool) or a provider starts streaming calls much earlier than their end. The design below is kept as written in case it does.

Today `streamTurn` finishes the whole turn and `execute` runs after it. opencode starts each tool when its call completes. Gain: the tail of the model's output overlaps the tools, and above all parallel `explore` calls (seconds to minutes each) start as soon as each is written.

- In `streamTurn`, on `.toolCallFinished`, start the tool in a `Task` stored in `Turn.early[id]` only if all of these hold: the tool is `.read`, not `waitsForUser`, offered in the current mode, passes `refusedByDenyRule`, and **no earlier call in this turn is an edit or command** (a read must still see the edits the model wrote before it).
- `execute` uses the early task's result instead of starting the tool, keeping call order, the repeat guard, shaping and `historyOutput` exactly as now. `.retrying` and Stop cancel every early task and discard results; a late result never reaches the history.
- Invariants to keep, each with a test: every call still has exactly one output; a cut-off call (`isComplete` false) is never started; the tool timeout still applies from the start time.
- Measure before keeping it: a `MockLLMClient` that streams two calls 200 ms apart with 300 ms tools, and a real `AgentEval` run. Keep the phase only if the saving is real on multi-call turns; if not, revert it and record the numbers here.
- Tests: `EarlyToolStartTests`.

## 5. General and background subagents

**Built, with these differences from the design below.** (a) Children get no command tools and cannot ask the user: any approval a child raises is answered with a refusal, and the forwarding of approvals/questions/plans to the host was **not** built. (b) A child that edits needs the parent in Accept Edits or Auto; in Manual it is refused. (c) `task` is an `.edit` tool (hidden in plan mode, runs alone), which gives the one-foreground-child rule for free; the one-writer rule covers the background case. (d) A run waits for background children, and a message the user queues meanwhile is delivered after the wait. (e) `explore` had never been added to Umbra's tool list; it is now, with `task`. (f) No UI for a child's own steps or a Stop button per child. Still open: approval routing so children can run commands, per-child cards, `model` override per agent, persisting child sessions.

Today `explore` is foreground, read-only, one level deep, and every call starts a fresh child. Add one `task` tool and keep `explore` unchanged (it is tested and its prompt is tuned).

- **Agent definitions.** `Skills/AgentDefinition.swift`, parsed with `MarkdownFrontmatter` from `.umbra/agents/*.md` and `.claude/agents/*.md` (project first, then user). Fields: `name`, `description`, `tools` (allow list; empty means all child-safe tools), `mode` (`plan` or the parent's), `max-iterations`, body is the child's extra system prompt. Built in: `explore` (read-only, as now) and `general` (all child-safe tools). The catalog listing goes into the `task` description, byte-stable and sorted, and into the session fingerprint.
- **`task` tool** (`Tools/TaskTool.swift`): `agent`, `description`, `prompt`, `background` (optional), `session` (optional, continue that child). Risk is `.read` only when the chosen agent is read-only; otherwise `.edit`, so plan mode hides it and approval modes see it.
- **Continue a child.** The parent keeps `children: [String: AgentSession]` for its lifetime and returns the id in the output (`<subagent session="…">`). Not persisted across a relaunch; the output says so when the id is unknown.
- **Edits by children.** The child gets the parent's `CheckpointLog` and run id, so Revert Run covers its edits (today a child has none). At most one edit-capable child runs at a time; read-only children are unlimited. Approvals, questions and plan decisions a child raises are forwarded as `.subagent` events, and `resolveApproval`, `answerQuestion` and `resolvePlan` look in the parent's pending set first and then in `children` by call id. Depth stays 1: a child's `task` answers with the depth limit.
- **Background.** The call returns at once with opencode's wording (running in the background; do not poll or sleep; work on something else or end the turn). The child runs in a task owned by the parent. On completion its summary (capped, wrapped as untrusted) is queued as an editor note and delivered at the next turn boundary through the existing `pendingMessages` path. A run does not end while a background child is still running: the point where a no-tool turn would end the run waits for it (same hook as queued messages), so no result crosses a run boundary. Stop cancels every child.
- **Budget.** Child tokens join the run budget as now, including background children.
- **UI** (`Umbra/Sources/Umbra/Agent`): the existing subagent row gains a "running in background" state and a Stop button for that child.
- Tests: `TaskToolTests` (definition parsing, read-only child cannot edit, general child edit is reverted by Revert Run, continue by id, depth limit, background result arrives once, the run waits, Stop cancels, an approval raised by a child reaches the host and resolves).
- Done when: two read-only children plus one editing child in one turn behave as above under `MockLLMClient`, and one real-model run delegates a search to a background child and finishes with its result.

## 6. `web_fetch`

**Built.** Differences from the design below: (a) the per-host ask is not a host gate but a new tool flag, `asksUnlessAllowed`, which routes a read through the permission rules and the approval card (it asks in plan mode too); (b) a redirect to another host is returned to the model as text rather than refused outright, so it can call again and be asked about the new host; (c) the DNS-rebinding limit stands; (d) HTML is converted by `HTMLText`, a tokenizer of about 300 lines, not a library. Checked live against example.com, a GitHub README (a same-host redirect), a cross-host redirect, localhost, 169.254.169.254 and a 404.

- `Tools/WebFetch.swift`, next to `WebSearch.swift` and built the same way: a `WebFetchClient` protocol, a `URLSession` implementation, host-added only when the user turns it on (Settings ▸ Agent, same toggle pattern and fingerprint entry as web search; no key needed).
- Input `url`, `format` (`markdown` default, or `text`), `timeout` (max 60 s). Output is wrapped untrusted, capped at 30 KB, and the rest goes through `headAndTailSaving` so `read_tool_output` can page it.
- Safety, which matters more here than in opencode because the app is sandbox-facing:
  - http and https only; refuse loopback, link-local, private-range and `.local` hosts, checked on the resolved addresses and again on every redirect hop; a redirect to another host is refused (as `web_search` does).
  - Text, HTML, JSON and XML content types only; stop reading at 2 MB.
  - The URL itself can leak data, so the first fetch of each host in a chat asks (the existing `PermissionGate`), with `WebFetch(domain:docs.swift.org)` allow rules and deny rules honoured (`honorsDenyRules`).
  - Known limit, to be documented: URLSession gives no way to pin the resolved address, so a DNS-rebinding host can in principle pass the pre-check.
- HTML to text: a small tokenizer in AgentKit (drop `script`, `style`, `nav`; headings, lists, links, `pre`/`code` kept as Markdown). No WebKit, no AppKit.
- Tests: `WebFetchTests` with a stub transport (redirects, private hosts, binary type, size cap, markdown conversion fixtures).

## 7. MCP client (stdio, tools only)

**Built.** Differences from the design below: (a) `MCPHub` (a new AgentKit actor) owns the connections, the restart-on-demand and the tool list; (b) trust is a fingerprint of the exact command, arguments and environment, asked once per project via an alert, not a Gradle-style per-folder trust; servers the user adds themselves are switched on with "Use"; (c) environment values the user types go to the Keychain; `${VAR}` expansion in project files is not done; (d) the servers are shared by every chat of the window (one process each), not started per chat; (e) a server's `readOnlyHint` is shown on the card as a claim and relaxes nothing; (f) a call is not cancelled on the server when Stop is pressed. Open: HTTP/SSE servers and OAuth (the config parser reports them as skipped), resources/prompts, a per-tool allow list, `list_changed`.

Reuses what ACP built: `JSONRPC.swift` and the newline-framed `ACPConnection` pattern.

- `AgentKit/MCP/`: `MCPConnection` over an injected transport (initialize handshake, `tools/list`, `tools/call`, timeouts, one terminal error per call), `MCPServerConfig` parsed from `.umbra/mcp.json` and `.mcp.json` (Claude Code's `mcpServers` format, read only).
- `ToolDefinition` gains an optional `rawSchema: JSONValue?` used by every encoder in place of the generated schema (byte-stable via `.sortedKeys`). This is the only change to existing code in the phase.
- `MCPTool: AgentTool`, named `mcp__<server>__<tool>`, risk `.command` so every call asks unless an allow rule names it; the server's `readOnlyHint` is not trusted. Output is wrapped untrusted and goes through the output shaper and saved-output path like any tool. Plan mode hides them.
- The tool list is fetched when the session is created, sorted by name, and its fingerprint joins the session fingerprint. `tools/list_changed` is ignored until the next session, which keeps the request prefix cacheable.
- Umbra (`Umbra/Sources/Umbra/Agent/MCP/`): the process transport over SubprocessKit; **per-server trust prompt before the first spawn**, remembered like Gradle trust and shown in Settings ▸ Agent ▸ MCP (list, enable, remove, last error); servers start on the first send of a chat and are killed at conversation teardown and window close (`IDEWorkspace.teardown()`). The App Store build hides the pane, as with the sandbox toggle.
- Phase 7b, only if wanted: streamable HTTP servers (consent per host, Keychain headers), then OAuth. Not in this plan's scope.
- Tests: `MCPConnectionTests` against a scripted fake server through the in-memory transport; a trust-prompt test; a teardown test that no process outlives the window.

## 8. Problems after an edit

**Built.** Differences from the design below: (a) the hook is asked once per *turn*, not once per edit call, and the note goes on the last edit's output; (b) the host cannot tell whether an editor report is newer than the edit without a baseline, so `IDEProblemsStore` counts reports per file and the agent's write path records the count (`noteAgentEdit`); (c) only open files the editor has already analysed take part, so nothing waits out a timeout on a `.txt` or a closed file; (d) the model sees the note, the transcript card does not.

Beyond opencode. After an edit batch, wait up to 1.5 s for the editor's own errors on the touched open files and append "Problems after this edit: …" to the tool output.

- `AgentConfiguration.afterEdit: (@Sendable ([String]) async -> String?)?`, called in `execute` once per edit batch. Umbra implements it over `IDEProblemsStore` (error severity only, at most 5 lines, project-relative paths). It never runs javac; the `diagnostics` tool stays the heavy path.
- Runs only on the agent path, never from a keystroke, so the performance rules are untouched. The wait is bounded and fails open.
- Tests: `AfterEditTests` (appended once per batch, timeout fails open, no note when clean).

## 9. Apple Intelligence (built 2026-10-24)

Apple's foundation model as a provider, on device and (macOS 27) on Private Cloud Compute. `Packages/AgentKitApple` holds the `LLMClient`; the problem it solves is that the framework runs tools itself, in the middle of a response, while AgentKit's loop approves and runs them. Details, limits and what is not verified: `Packages/AgentKitApple/CLAUDE.md`; Umbra side: `Umbra/Sources/Umbra/Agent/CLAUDE.md` ("Apple Intelligence").
- Decisions: Chat always, Code only where the window is large enough (the on-device 8K is chat only; gate 16,384); PCC included, behind the usual per-host consent; no reasoning setting; one package, not folded into AgentKitMLX (different deployment target, no MLX dependency).
- Open: confirm PCC generation from the app (`ModelManagerError 1046` from the test host), map reasoning effort to macOS 27's `ReasoningLevel`, an `explore`/`task` child on Apple's model, and re-measure Code's overhead if the tool list grows.

## Docs to update as phases land

`Packages/AgentKit/CLAUDE.md` (retries, arguments, snapshot seam, early start, `task`, `web_fetch`, MCP), `Umbra/Sources/Umbra/Agent/CLAUDE.md` (snapshotter, background subagent UI, MCP pane, web fetch toggle), and the memory note `agent-harness-decisions`.
