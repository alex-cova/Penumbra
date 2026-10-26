# Harness gap 3: user-configurable hooks

Part of the series `agent-harness-1.md` to `agent-harness-7.md` (index: `README.md`). Checked against the code on 2026-10-26.

**Status:** decision needed. `docs/harness/BUILT.md` lists "user-configurable tool hooks" under "Not planned". If this is approved, update that line.

## What exists today

- **No hooks.** Nothing in `Packages` or `Umbra/Sources` reads a `hooks` key or mentions `PreToolUse`/`PostToolUse`.
- **Host callbacks on `AgentConfiguration`** (`Packages/AgentKit/Sources/AgentKit/Session/AgentConfiguration.swift`): `gate: (any PermissionGate)?`, `pendingMessages`, `runIsOverCost`, `policies: [any TurnPolicy]`, `shapeToolOutput`, `currentInstructions`, `toolOutputStore`, `snapshotter`, `afterEdit` (+ `afterEditTimeout`). Umbra fills them in `IDEAgentConversation.currentSession`.
- **How a call is decided** (`Session/AgentSession.swift`, `execute`): a plan is built per call (repeat guard, mode check, `tool_call` forwarding, unknown tool), then a batch loop. Concurrent reads only go through `refusedByDenyRule`; everything else goes through `approved(...)`. `approved` returns early unless `configuration.approval == .askForCommands`, so under `.approveAll` (AgentEval, any CLI) it is skipped. `PermissionPolicy.evaluate` runs inside it: deny rule, then `gate`, then ask rule, then allow rule, then the mode. After the run: `.toolCallFinished` with the original output, then `afterEdit`, then `historyOutput` (shaper, then `ToolOutputNet.spill`).
- **`PermissionGate` is not enough for a hook.** It sees `ToolCallInfo` (name, risk, subject, flags), not the raw arguments, and it is never asked about plain reads.
- **Settings files already exist.** `IDEAgentPermissionFiles` reads `~/Library/Application Support/com.umbra.editor/permissions.json` and, in the project, `.umbra/settings.json`, `.umbra/settings.local.json`, `.claude/settings.json` and `.claude/settings.local.json`. `PermissionRules.fromSettings` parses only `permissions.allow/ask/deny`. It does not read `~/.claude/settings.json`.
- **A stop mechanism exists.** `StopGatePolicy: TurnPolicy` (`Session/TurnPolicy.swift`): `check: (StopGateInput) async throws -> StopGateVerdict` (`pass`, `skip`, `block(reason:)`), runs only from `beforeEnding`, never in plan mode, fails open, default 3 continuations, 600 s timeout, 4,000-character reason cap. Umbra uses it for "Run tests before finishing".
- **A consent pattern exists.** The MCP project-server trust (`IDEMCPStore`: SHA-256 fingerprint, `trusted`/`declined` sets, re-asks on change; prompt through `IDEAgentHost.agentConfirmMCPServers`).
- **A runner exists.** `SubprocessRunner.run(_:)` (`Packages/SubprocessKit`) with `SubprocessRequest.standardInput = .data(Data)`, `stdoutCapture = .bounded(head:tail:)`, `timeout`, `processGroup`; Umbra's `AgentCommandRunner` and `AgentCommandEnvironment.make` (login PATH) wrap it.
- **The session fingerprint** (built in `currentSession`: settings, root, Gradle/Maven flags, skills, agents, MCP hub, memory) decides whether a chat keeps its `AgentSession`. Permission rules are re-read on every send and are not in it.

## Gap

Users cannot format on edit, block a command pattern with a script, run a linter after a change or get a notification when a run ends. Claude Code users rely on this.

## What Claude Code does

- Events: `PreToolUse` (allow, deny or modify), `PostToolUse` (feed text back), `UserPromptSubmit`, `Stop`, `SubagentStop`, `SessionStart`, `Notification`.
- Configured under a `hooks` key in `settings.json`; matcher by tool name; the call arrives as JSON on stdin; exit 0 continues, exit 2 blocks and the stderr goes to the model.

OpenCode does the same through plugins.

## Proposal

Shell-command hooks only, in the settings files Umbra already reads, using Claude Code's shape so existing `.claude/settings.json` hooks work.

1. **AgentKit side: a protocol, no process.** `ToolHooks` on `AgentConfiguration` with `before(_ call: HookCall) async -> HookDecision` (`allow`, `deny(reason)`, `ask`) and `after(_ call: HookCall, output: String) async -> String?`. `HookCall` carries tool name, risk and the raw `ToolArguments`. AgentKit never spawns anything.
2. **Insertion points in `AgentSession.execute`.** The before-hook goes in the per-call batch loop **before** the `refusedByDenyRule` / `approved(...)` branch, so it covers concurrent reads and `.approveAll`. A hook `deny` is final and beats an allow rule; `ask` forces an approval card even when a rule allows. The after-hook goes in the `for (index, output) in batch` loop next to `afterEdit`: its text reaches the model and still passes through the shaper; `.toolCallFinished` keeps the original.
3. **Stop hook** is another `TurnPolicy` modelled on `StopGatePolicy`: `block` feeds the reason back and the run continues, bounded by the same continuation cap, fails open.
4. **Umbra side.** A `hooks` parser next to `PermissionRules.fromSettings` (same files, merged in the same order); a runner on `AgentCommandRunner` with stdin JSON `{session_id, cwd, hook_event_name, tool_name, tool_input, tool_response?}`, bounded output, a per-hook timeout (default 30 s), the login-PATH environment, project root as working directory. Exit 0 continues (stdout is added context for after-hooks); exit 2 blocks and stderr goes to the model; any other failure warns and fails open.
5. **Matchers and names.** A matcher is a regex or glob over the tool name (`GlobPattern`). Umbra's names differ from Claude Code's, so ship a small alias table (`Bash` → `run_command`, `gradle`, `maven`, `project_task`, `run_tests`; `Edit`/`Write`/`MultiEdit` → `edit_file`, `write_file`, `apply_patch`; `Read` → `read_file`; `Grep`, `Glob` → the search tools) so a `.claude/settings.json` matcher keeps working.
6. **Consent.** Hooks run code. The first time a project's `hooks` block is seen, show it and ask; store a fingerprint of the block (the `IDEMCPStore` pattern) and ask again when it changes. A hook from an untrusted project never runs. User-level hooks (the app `permissions.json`) need no prompt. This stays in the host layer, outside the core editor engine, which keeps the App Store rules in the root `CLAUDE.md` intact.
7. **Fingerprint.** The hooks fingerprint joins the session fingerprint in `currentSession`.
8. **Events in phase 1:** `PreToolUse`, `PostToolUse`, `Stop`. `UserPromptSubmit`, `SessionStart` and `Notification` later.

## Rules to keep

- A hook `deny` overrides an allow rule, never the other way round.
- Hook output going to the model is untrusted content (`UntrustedContent`), and stderr is capped.
- A slow or failing hook must not hang a run: timeout, then warn and fail open, unless the hook is marked `"required": true`.
- Hooks apply to the agent's tool calls only. They never run for the user's own edits or commands.
- Hooks apply to subagent calls too (the child gets the same `ToolHooks`).

## Tests

- `ToolHooksTests` in `Packages/AgentKit/Tests` with a fake host: deny stops the call and the model sees the reason; ask forces an approval despite an allow rule; an after-hook's text is appended and shaped; a throwing hook fails open; the hook runs under `.approveAll` and for a concurrent read.
- Umbra (`Umbra/Tests/UmbraTests`): parsing from `.claude/settings.json`; the alias table; consent asks again after the block changes; stdin JSON shape; exit-code mapping; timeout.

## Done when

A project `.claude/settings.json` with a `PostToolUse` hook on `Edit|Write` that runs a formatter formats files the agent edits after the user approves the hook once; a `PreToolUse` hook that exits 2 on `rm -rf` stops that command and the model sees the reason; editing the hook asks again.

## Size

AgentKit protocol and insertion points: M. Umbra parser, runner, consent: M.

## Open questions

- Is the Claude Code settings shape worth copying exactly, or should Umbra define its own schema and only import the common subset?
- Should hooks also be offered in the `umbra-agent` CLI (`agent-harness-6.md`)? Probably yes, with consent replaced by an explicit `--allow-hooks` flag.
