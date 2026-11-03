# Harness gap 7: smaller items

Part of the series `agent-harness-1.md` to `agent-harness-9.md` (there is no index file; `ls docs/harness`). Checked against the code on 2026-10-26. Each item is independent and small; none blocks parity.

**Status:** items 1–4 built (checked 2026-11-02): the measurement is saved (with the caveat in item 1), `/export json` writes a scrubbed `SessionStore` snapshot, the navigation text and `IDEJavaAgentNavigator` are cleaned up and `hover` and `rename_symbol` exist, and `/loop` ships. Items 5 and 6 stay on demand.

## 1. Measure what is already built

**What exists.** An earlier `BUILT.md` (deleted in `e7b8d169`) said tolerant tool arguments were "not yet measured with AgentEval". AgentEval supports `--trials N`, `--jobs N`, `--json` and `--transcripts` (`Tools/AgentEval/Sources/AgentEvalKit/Options.swift`, `Report.swift`), but **no results are saved anywhere in the repo**. Nothing in the repo supports an earlier note that the full-versus-core toolset was "inconclusive at 16 trials"; it came from session notes.

**Proposal.** Save `--json` results under `Tools/AgentEval/Results/<date>-<change>.json`, and record one summary line (provider, model, trials, pass count) in the doc that motivated the change. Measure tolerant arguments first. AgentEval now has Anthropic and Meta providers (`Tools/AgentEval/Sources/AgentEval/Providers.swift`).

**Done when.** The tolerant-arguments line carries a measured number *and a baseline to compare it with* (met on 2026-11-03 with the caveat below). **Size:** S.

**Measured 2026-11-02, invalid** (`Tools/AgentEval/Results/2026-11-02-tolerant-arguments.json`): 21/42 is not a pass rate. 20 of its 21 failures are `Could not connect to localhost` across seven tasks (`implement-roman`, `injection`, `long-session`, `noisy-tests`, `read-large-file`, `rename-across-files`, `trace-deep-bug`): Ollama was unreachable and those trials never ran. An earlier version of this note said only `trace-default` was affected; the JSON says otherwise. The file is kept for the record and must not be used as a baseline.

**Measured 2026-11-03** (`AgentKit`'s `ToolArguments.isTolerant`, AgentEval `--strict-arguments`; a measurement hook, not a product setting): ollama · qwen-fixed:latest · full toolset · 14 tasks × 3 trials.
- **Strict arguments** (`Results/2026-11-03-strict-arguments.json`): 37/42. `read-large-file` 0/3 is an Ollama `500` server error, not an argument problem; `implement-roman` 1/3 (a failing test and a timeout); the other twelve tasks 3/3.
- **Tolerant arguments** (default): the clean run was cut short. The Mac hibernated on battery at 01:34 (`caffeinate -s` holds only on AC power) and the run was killed after the wake, so no JSON was written. Its log has the first 26 of 42 trials: 26/26 passed, against 24/26 for the same 26 trials in the strict arm (the two misses are `implement-roman`).
- **What it says.** No strict-arm transcript has an argument-type error ("must be an integer", "must be true or false", "must be a list of strings"), so strict mode changed no call: this model sends well-typed arguments and the tolerance had nothing to repair. The 2-trial gap is run-to-run noise at this size. The measure that would show a benefit is rejected calls per run on a model that does make type mistakes; the pass count cannot. **Conclusion: unmeasured as a benefit, shown unnecessary for `qwen-fixed:latest`.** Keep the tolerance (it costs nothing and the unit tests cover what it reads); do not claim it helps until a weaker model shows rejected calls in strict mode.
- A trial that spans a system sleep records the sleep in `seconds` and can end `timeout`, because the trial deadline is wall-clock.

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

**What exists.** An earlier `BUILT.md` (deleted in `e7b8d169`) said: "Not planned: a durable SQLite inbox, image pruning (AI mode is text-only), a plugin system, LLM-written chat titles, user-configurable tool hooks." Skills, commands, agent definitions and MCP config already cover most of what a Claude Code plugin ships; hooks are proposed in `agent-harness-3.md`.

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
