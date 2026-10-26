# Harness gap 7: smaller items

Part of the series `agent-harness-1.md` to `agent-harness-7.md` (index: `README.md`). Checked against the code on 2026-10-26. Each item is independent and small; none blocks parity.

**Status:** open. Take them in the order at the end.

## 1. Measure what is already built

**What exists.** `docs/harness/BUILT.md` says tolerant tool arguments are "not yet measured with AgentEval". AgentEval supports `--trials N`, `--jobs N`, `--json` and `--transcripts` (`Tools/AgentEval/Sources/AgentEvalKit/Options.swift`, `Report.swift`), but **no results are saved anywhere in the repo**. Nothing in the repo supports an earlier note that the full-versus-core toolset was "inconclusive at 16 trials"; it came from session notes.

**Proposal.** Save `--json` results under `Tools/AgentEval/Results/<date>-<change>.json`, and record one summary line (provider, model, trials, pass count) in the doc that motivated the change. Measure tolerant arguments first. AgentEval has no Anthropic or Meta provider; `agent-harness-6.md` phase 1 fixes that.

**Done when.** The tolerant-arguments line in the plan carries a measured number. **Size:** S.

## 2. Session export

**What exists.** `IDEAgentTranscriptExport.markdown(title:entries:exportedAt:)` (`Umbra/Sources/Umbra/Agent/Commands/IDEAgentTranscriptExport.swift`), reached from `/export` and saved as `.md` (`IDEAgentController+Commands`). No JSON export.

**Proposal.** A JSON export of the `SessionSnapshot` (`Packages/AgentKit/Sources/AgentKit/Session/SessionStore.swift`) without the opaque `host` blob, with text passed through `IDEAgentOutputScrubber.scrub`, for bug reports and for `umbra-agent` (`agent-harness-6.md`). Add a "tools hidden" option to the Markdown export. No hosted share link: that is a network feature nobody asked for.

**Done when.** `/export json` writes a file that `SessionStore` can read back. **Size:** S.

## 3. Language-server tools: rename and hover

**What exists (the first version of this doc was wrong here).** The agent navigation tools are not Java-only. `agentJavaNavigator()` returns `IDEEngineAgentNavigator(engine: navigationEngine)` (`IDEWorkspace+Agent.swift`), so `go_to_definition` and `find_usages` answer for every registered language: Java natively, Swift through SourceKit-LSP and TypeScript/JavaScript through typescript-language-server (`IDEIntelligenceServices`, `EditorIntelligenceLSP`). The tools are offered for Gradle, SwiftPM, Xcode or npm projects, or when a source file of those languages is open. `find_symbol` and `explore_symbol` use `JavaIndex`, `SwiftIndex` and `TypeScriptIndex`.

**Stale text to fix** (these mislead the model and the next reader):
- "the Java index is still building" in the "No definition found…" messages of `IDEAgentNavigationTools.swift`.
- `IDEJavaAgentNavigator` is now used only by tests; remove it or move it to the tests.
- The description of the navigator as Java-only in `Umbra/Sources/Umbra/Agent/CLAUDE.md`.

**Proposal.** Two new tools in `IDEAgentNavigationTools.swift`:
1. `hover` (`.read`): type and documentation at a location, over `IDEIntelligenceServices.hoverEngine`.
2. `rename_symbol` (`.edit`): `LanguageServiceRegistry` routing gives `prepareRename`/`rename(_:to:) -> RenamePlan`; apply the plan through `IDEWorkspaceEditApplier` so it is checkpointed and covered by Revert Run, with the usual diff for approve-each-edit mode.

**Done when.** The agent renames a Swift method across files in one call and Revert Run restores them. **Size:** S for the cleanup, M for the two tools.

## 4. `/loop`

**What exists.** The built-in slash commands are `new, clear, resume, rewind, fork, compact, plan, mode, permissions, model, history, export, init, cost, rename, help` (`IDEAgentBuiltInCommand`). Nothing repeats a prompt.

**Proposal.** `/loop <interval> <prompt>` re-sends the prompt in the same chat on a timer while the app is open, one run at a time, stopping on the Stop button, an error, a budget stop or a count limit (default 10). It never runs while a run is active or an approval is pending. A schedule that survives quitting needs a launchd job and the headless CLI from `agent-harness-6.md`, so it waits for that.

**Done when.** `/loop 5m check git status and tell me if anything changed` runs three times and stops on Stop. **Size:** S to M.

## 5. Output styles

**What exists.** No named style in Code chats. The closest thing is AI-mode Chat's editable `chatSystemPrompt` (`AIMode/IDEAISettings.swift`, key `umbra.ai.chatSystemPrompt`).

**Proposal.** A style is one extra block in the system prompt chosen per chat, part of the session fingerprint. Only on demand; the value is low until users ask.

## 6. Plugin bundle format

**What exists.** `docs/harness/BUILT.md` says: "Not planned: a durable SQLite inbox, image pruning (AI mode is text-only), a plugin system, LLM-written chat titles, user-configurable tool hooks." Skills, commands, agent definitions and MCP config already cover most of what a Claude Code plugin ships; hooks are proposed in `agent-harness-3.md`.

**Proposal.** A folder with a manifest that installs skills, commands, agents, MCP servers and hooks together and removes them cleanly. Revisit only after hooks and HTTP MCP exist and users are sharing configurations by hand. If built, update the "Not planned" line.

## Order

1. Measure the unmeasured items (1).
2. Fix the stale navigation text (3, cleanup half).
3. Session export (2).
4. `hover` and `rename_symbol` (3).
5. `/loop` (4).
6. Output styles and plugin bundles (5, 6), only on demand.

## Open questions

- Is rename worth an `.edit` tool at all, or should the agent keep using `edit_file` across the `find_usages` results?
- Should `/loop` count against the cost and token limits of the chat (yes by default), or have its own cap?
