## Goal

Finish the Codex/Grok-inspired harness work in dependency order: surface rule self-test failures in Umbra, then a blocking Stop gate, a tool-output shaper, opt-in project memory, a read-only explore subagent, and an opt-in Seatbelt profile for agent commands in direct (non-App Store) builds.

## Success Criteria

- A rule whose `match`/`not_match` examples fail shows a warning badge in Settings ▸ Agent ▸ Permissions that names the example and the expected result. The rule still applies.
- A host can stop a run from ending `.completed` until its check passes. It gets at most N continuations per run (default 3), then the run ends anyway and the final answer says the check did not pass. A check that errors or times out fails open.
- A host can redact or trim a tool's output before it goes into `items` (what the model sees and `SessionStore` saves). `.toolCallFinished` still carries the original for the live transcript.
- With memory turned on, decisions survive across chats through a per-project memory file outside the repo. The user can review and delete it. The model adds to it only through one gated tool.
- The model can hand read-only research to a child session with its own context window. The parent receives a capped summary, and the child's tokens count against the parent run's budget.
- In direct builds, agent commands can run under an opt-in `workspace` Seatbelt profile after first-use consent. A command that the sandbox blocked can be retried unsandboxed through the existing approval card.

## Approach

Every step is pure AgentKit first, then Umbra wiring. Each one plugs into a seam that already exists:

| Need | Existing seam |
|---|---|
| Stop gate | `TurnPolicy.beforeEnding` + `AgentConfiguration.policies` |
| Output shaping | the `items.append(.toolOutput…)` sites in `AgentSession` |
| Memory | `ProjectInstructions` loader shape, `SessionStore` directory, skill-style fingerprinting |
| Subagent | `AgentSession` + `DiskAgentWorkspace` + plan-mode tool filtering (`AgentTool.isOffered(in:)`) |
| Sandbox | `IDEAgentCommandRunner.make` building argv for SubprocessKit |

App Store safety follows [CLAUDE.md](/Users/alex/Developer/Penumbra/CLAUDE.md). Nothing in `Sources/Penumbra`, `Sources/EditorIntelligence` or AgentKit spawns processes or applies OS sandboxing. Running the check behind the Stop gate and the Seatbelt profile stays in `Example/Umbra`.

Steps 2 and 3 are the in-process equivalents of Codex/Grok's `Stop` and `PostToolUse` hooks, and `PermissionGate` already plays the `PreToolUse` role. User-configured command hooks can later sit on top of these seams (see Non-goals).

## Steps

1. **Rule self-test badges (Umbra only).**
   - `IDEAgentPermissionsModel.reload()` already gets each file's `PermissionRules` from `IDEAgentPermissionFiles.loadEach`. Call `rules.checkExamples()` per source and attach the `[ExampleFailure]` to the matching `Entry` (match on rule + kind).
   - `IDEAgentPermissionsSection` shows a warning glyph with a tooltip such as "`git status --short` should match but does not".
   - Files: `Example/Umbra/Agent/Permissions/IDEAgentPermissionsModel.swift`, `IDEAgentPermissionsSection.swift`.
   - Tests in `IDEAgentPermissionsModelTests`: a file with one failing and one passing example gives exactly one badge on the right entry; a file with no examples gives none.

2. **Blocking Stop gate (AgentKit).**
   - New `StopGatePolicy: TurnPolicy` in `Session/TurnPolicy.swift`. Its check is a host closure, `@Sendable (StopGateInput) async -> StopGateVerdict`.
     - `StopGateInput`: `filesEdited`, `verifiedSinceEdit`, `continuations` (Codex's `stop_hook_active`), the last assistant text.
     - `StopGateVerdict`: `.pass`, `.block(reason:)` or `.skip`.
   - Asked only from `beforeEnding`, so stopped, budget, iteration-cap and failed runs skip it, the same way Grok skips interrupted turns. Never asked in plan mode, or when no file was edited unless the host says otherwise.
   - On `.block`, return `.note(reason)` with the reason capped like tool output. The loop continues, and `RunLimitPolicy` still bounds it.
   - After `maxContinuations` (default 3, lower than Grok's 8 because of local models), return `.finalTurn(note: "The check still fails: … Say so plainly.", ending: .completed)`.
   - A check that throws, is cancelled (Stop) or exceeds `timeout` (default 600 s, as in Codex/Grok) counts as `.pass`, and the session records why.
   - New event `.stopGateChecked(passed: Bool, summary: String)` so the UI can show it. Update the exhaustive switches in Umbra and in ACP `ACPAgentEndpoint`.
   - Reset per run like `VerifyBeforeStoppingPolicy`. That policy stays as the soft nudge, and a host uses one or the other.
   - Umbra: Settings ▸ Agent toggle "Run tests before finishing", wired to `IDERunTestsTool`'s runner. Off by default.
   - Tests: new `StopGateTests`: block then pass, cap reached, timeout fails open, Stop during the check, plan mode skipped, every call still answered.

3. **Tool-output shaper (AgentKit).**
   - `AgentConfiguration.shapeToolOutput: (@Sendable (ToolOutputShapingInput) async -> String)?`. The input carries tool name, arguments, risk, `isError` and text.
   - Applied in one private helper that replaces the `.toolOutput` appends in `AgentSession`. The "Not run…" and cancel stubs skip it.
   - `.toolCallFinished` still yields the original. The shaped text is what reaches `items`, and so the model, `SessionStore` and compaction.
   - Document the contract beside `SecretFilePolicy`:
     - Redaction must happen here, so secrets never reach `items` or disk.
     - The host's own transcript blob keeps the original only if the host chooses to.
     - The shaper must be deterministic for a given input (prompt-cache stability).
     - Errors and timeouts fall back to the original.
   - Umbra: first user is a regex scrubber for common token shapes (AWS keys, `ghp_`, `sk-`, PEM blocks), applied to command and web output.
   - Tests in `ToolOutputShapingTests`: the shaped text is in `items`, the event has the original, a cancel stub is untouched, a throwing shaper falls back.

4. **Opt-in project memory (AgentKit + Umbra).**
   - Storage is `<SessionStore dir>/<project hash>/MEMORY.md` (0600), outside the repo, so it's never committed and never falls under `WriteProtection`.
   - `ProjectMemory.load(at:)` uses the `ProjectInstructions` loader shape: 8 KB cap, symlinks refused, oldest entries dropped first.
   - Memory goes into the system prompt under "Notes remembered from earlier chats (may be stale; the project's files and instructions win)". It's a recall layer, never instructions, as in Codex.
   - Loaded at session start only. Its fingerprint joins the session fingerprint, so a write never changes a live request; it's visible from the next session on.
   - The model writes through one `remember` tool, not `edit_file`. `remember` appends one dated line of at most 300 characters, deduplicated, and passes through the step-3 shaper for redaction.
   - Risk: `.edit` (not offered in plan mode). It always shows an approval card unless the user turned on "Save memories without asking". Even then, a run that used `web_search` or read untrusted content asks, matching Codex's `disable_on_external_context` (it limits prompt-injection persistence).
   - Umbra: off by default. Settings ▸ Agent ▸ Memory gets an on/off toggle, "Open file" and "Delete memories".
   - Tests in `ProjectMemoryTests`: load, cap, symlink refused, append persists, duplicate ignored, the live request bytes stay the same after a write, an untrusted-context run asks.

5. **Read-only explore subagent (AgentKit).**
   - `ExploreTool` (`explore`, `.read`, takes `task: String`) runs a child `AgentSession` over the parent's workspace and `ReadLedger` copy.
     - Child tools: the parent's plan-mode tool list minus `ask_user`, `exit_plan_mode`, `todo`, `explore` and `remember`. Calling `explore` from the child returns a depth-limit error, as in Grok.
     - The child runs in the foreground only (no background IDs in v1).
   - The child shares the parent's `LLMClient`, model and permission rules, with its own `contextWindow` and compaction (60% for Ollama, as today). It has a hard iteration cap (default 15).
   - The final step forces a summary turn with no tools. The summary is capped at 6 KB, wrapped as untrusted, and is the tool's output.
   - The parent's Stop and the tool timeout cancel the child. The child's usage is added to the parent's run usage, so `RunLimitPolicy` token and cost budgets include it.
   - Events: the child's events are forwarded wrapped as `.subagent(id:event:)` so Umbra can render a collapsible card. This is CopilotKit's lesson of showing what a delegated agent is doing, not only its result.
   - Tests in `ExploreSubagentTests`, with a `MockLLMClient` script for each side:
     - the child cannot edit (an edit call gets "not available");
     - the parent gets the summary;
     - every call is answered on both sides;
     - Stop mid-child ends both with one `.runEnded`;
     - depth limit;
     - usage adds up.
   - AgentEval: same tasks with and without `explore`, `--trials 3`, comparing pass rate, compaction count and total tokens on a small local model.

6. **Seatbelt `workspace` profile for agent commands (Umbra, direct builds only).**
   - `IDEAgentCommandRunner.make` wraps argv as `/usr/bin/sandbox-exec -p <profile> -- …` when the profile is on. SubprocessKit stays generic.
   - Profile, after Codex workspace-write and Grok `workspace`:
     - reads allowed everywhere except the credential paths below;
     - writes allowed to the project root, `TMPDIR`, `/tmp`, `~/.gradle` and `~/.m2`;
     - `.git` and Umbra's own config are read-only;
     - reads and writes denied to `~/.ssh`, `~/.aws`, `~/.config/gh`, `~/Library/Keychains` and the `SecretFilePolicy` globs;
     - network allowed by default (Gradle/Maven resolve), with a "Block network" option.
   - Chosen per session, never changed mid-run (Grok). First use shows a consent sheet. Off by default.
   - Retry outside the sandbox (Codex on-failure): when a command exits nonzero and stderr shows a Seatbelt denial (`Operation not permitted` / `deny(1)`), the output says so and the session raises an approval card, "Run outside the sandbox?". Rules can pre-allow known prefixes.
   - Mac App Store build: the toggle is hidden. The App Sandbox already confines children, and `sandbox-exec` cannot nest. Detect this at runtime through the `APP_SANDBOX_CONTAINER_ID` environment variable.
   - `sandbox-exec` is deprecated but still ships and is what Codex uses. If a future macOS removes it, the toggle disappears.
   - Tests in `IDEAgentCommandToolTests`: argv wrapping, profile text for a given root, the denial message detected, the retry card raised.
   - Manual check on a signed direct build: a write outside the root is denied, `./gradlew build` succeeds, `cat ~/.ssh/id_*` is denied.

## Validation Plan

- AgentKit steps (2–5): the focused suite first (`swift test --filter <Suite>` in `Packages/AgentKit`), then the full AgentKit suite. Run Umbra surfaces through the matching `Tests/PenumbraTests/IDEAgent*` suites under `caffeinate -u -d -i -s swift test`.
- Step 2 also runs on a real Ollama model (`OllamaSmokeTests` style) with a failing test fixture, to check the cap ends the run with an honest answer.
- Step 5: the AgentEval comparison above, with numbers recorded in the commit message.
- Step 6: no claim based only on green tests; the signed-build manual check is required.

## Risks / Open Questions

- Stop gate loops on models that can't fix the failure: hence the low cap, fail-open, and handing `continuations` to the check so it can give up early.
- Subagent cost: one call can spend a large share of the budget. The iteration cap and shared run budget bound it, and AgentEval shows whether it pays off on small local models.
- Memory as an injection channel: limited by approval-by-default, the untrusted-context rule, the per-entry cap and the user-visible file.
- Shaper and prompt cache: a nondeterministic shaper breaks prefix caching. This is documented, and a test encodes the same request twice.
- Seatbelt false positives (tools writing to `~/Library/Caches`, `~/.cache`): start with Gradle/Maven, collect denials from the log, and widen deliberately.

## Non-goals

- User-configured command hooks (Codex `hooks.json`, Grok hooks). They can come later on top of steps 2–3 and `PermissionGate`, and would need hash-based trust before any project hook runs, as Codex does.
- MCP client support, background or parallel subagents, personas, worktree isolation, nesting deeper than 1, cloud execution, auto-generated memories (Codex's background pass).

## Sources

- [Codex rules (prefix_rule, match/not_match)](https://learn.chatgpt.com/docs/agent-configuration/rules)
- [Codex hooks (Stop block + stop_hook_active, PostToolUse replaces result, trust by hash)](https://learn.chatgpt.com/docs/hooks)
- [Codex memories (off by default, recall layer, disable_on_external_context)](https://learn.chatgpt.com/docs/customization/memories)
- [Codex sandboxing (workspace-write, escalation via approval)](https://learn.chatgpt.com/docs/sandboxing)
- [Grok Build sandbox profiles](https://raw.githubusercontent.com/xai-org/grok-build/main/crates/codegen/xai-grok-pager/docs/user-guide/18-sandbox.md)
- [Grok Build permissions and safety](https://raw.githubusercontent.com/xai-org/grok-build/main/crates/codegen/xai-grok-pager/docs/user-guide/22-permissions-and-safety.md)
- [Grok Build hooks (Stop cap of 8, fail-open, skipped turns)](https://raw.githubusercontent.com/xai-org/grok-build/main/crates/codegen/xai-grok-pager/docs/user-guide/10-hooks.md)
- [Grok Build subagents (depth limit, explore is read-only)](https://raw.githubusercontent.com/xai-org/grok-build/main/crates/codegen/xai-grok-pager/docs/user-guide/16-subagents.md)
- [CopilotKit / AG-UI (human-in-the-loop, rendering agent progress)](https://github.com/CopilotKit/CopilotKit)
