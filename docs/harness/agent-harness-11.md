# Harness gap 11: other lessons from T3 Code

Part of the series `agent-harness-1.md` to `agent-harness-11.md` (there is no index file; `ls docs/harness`). Checked against the code on 2026-11-24, against the T3 Code tree (`docs/internals/*.md`, `docs/user/*.md`). The largest item from the same comparison, portable handoffs, has its own doc: `agent-harness-10.md`.

**Status:** items 1, 4 and 5 built 2026-11-24; items 2 and 3 are proposals. Each item is independent.

## Already equal or better (checked, no work)

These came up in the comparison and Umbra already does them:

- **Usage limits vs. rate limits.** A 429 with `insufficient_quota` becomes `.api(code: "insufficient_quota")`, not a retry (`OpenAI/HTTPErrorClassifier.swift`). T3's `usage_limit` rule is met.
- **Early Stop.** `IDEAgentConversation.stop()` sends `session/cancel`, waits 2 s, then terminates the process group. An agent that ignores the cancel cannot strand the chat.
- **Settlement on every terminal path.** `ACPClientSession.stop()` and `handleClose(error:)` both answer pending permissions, finish unanswered calls, cancel interactions and end the run exactly once.
- **Passive health checks.** `prepareACP()` starts an agent only when the model picker opens, never because a chat is shown.
- **Never offer what is not advertised.** `setModel` refuses a model the agent did not list. `selectableChoices` never invents options.

## 1. A cross-chat usage view (built 2026-11-24)

**Today:** cost and `usageByModel` are saved per chat in `SessionStore`. No view adds them up (none found under `Umbra/Sources/Umbra`).
**T3:** one Usage page across providers: tokens, cache savings, cost per model, trends, and a 90-day retention setting.
**Proposal:** a "Usage" sheet (Settings ▸ Agent, or `/usage`) that reads the saved chats of the current project, or of all projects. It shows totals by model and by day, cache-read share, and local models at $0. Read the store, never re-price history; old rows use the prices saved with them.
**Size:** small. No harness change.

**Built:** `/usage` opens `IDEAgentUsageSheet` from the agent panel (docked, page and AI mode's Code): This Project or All Projects (which adds AI mode's Chat), 7/30/90 days or all time; tiles for cost, input (with the cached share), output and chats; cost per day (tokens per day when nothing in the period has a cost); tables by model and, for all projects, by project. `IDEAgentUsageLoader` reads the saved files off the main actor, decodes only the usage fields, skips files last written before the period, and stops at the newest 5,000. Nothing is re-priced: a chat's recorded cost goes, whole, to the model that did most of its work (helper models are priced at 0 anyway). A chat counts on the day it was last used, since that is all a file says. Chats now save their per-model split (`IDEAgentSavedTranscript.usageByModel`); an older file puts its total on its model, else "Model not recorded". Not built: retention settings (the store is the history), ACP agents that never report usage show no tokens. Tests: `IDEAgentUsageTests` (report, loader over a real `SessionStore`, the saved split; `AI_MODE_PNG_DIR=… --filter testTheSheetRendersSeededChats` writes `usage-sheet.png`).

## 2. Scheduled prompts that survive a relaunch

**Today:** `/loop` repeats a prompt in the same chat while the window is open, and skips a tick while a run or approval is pending. It stops on relaunch.
**T3:** scheduled tasks (timer or webhook) and durable workflows whose step results are saved, so a restart resumes them.
**Proposal:** keep T3's shape but stay in-process, for App Store safety (no background agent, no launchd).
1. `IDEAgentSchedule`: prompt, project, cadence, model, mode, and the last run's result. It is saved beside the chats.
2. It fires only while Umbra is running. A tick missed while Umbra was closed runs once on launch, after a visible notice, and is never replayed for every missed tick.
3. Every run opens its own chat titled "<schedule> · <date>", so its approvals and history behave like any other chat.
4. Auto mode stays opt-in per schedule, and the first run of a schedule always asks.

Webhooks and multi-step workflows stay out of scope: they need a listening server.
**Size:** medium.

## 3. Replay fixtures recorded from real ACP agents

**Today:** `ACPTests.swift`, `ACPProviderExtensionTests.swift` and `ACPAgentEndpointTests.swift` use hand-written JSON-RPC frames.
**T3 rule:** "Hand-written protocol frames guess at wire behavior". Adapter behaviour is proven with fixtures recorded from the real provider and replayed through the real adapter.
**Proposal:**
- A recording transport (debug builds only, opt-in through a setting) that writes each frame, with its direction and relative time, to a `.jsonl` file. It goes through `IDEACPSecretScrubber`.
- A `ReplayTransport` in `AgentKit/Testing` that plays a file back and fails on an unexpected client frame.
- Record one turn each from Claude Code, Codex, Kiro and Muse, covering a tool call, a permission request, a Stop and a disconnect. Kiro's late `config_option_update` and Muse's sign-in message are the quirks that have broken before.
**Size:** small to medium. It catches adapter upgrades that change wire behaviour, which is what the managed-adapter updates risk.

## 4. Startup phase from real signals (built 2026-11-24)

**T3 rule:** a starting turn shows which step it is on ("starting agent", "signing in", "loading session", "waiting for model") only from protocol signals, never from a timer, and clears the step at the first output.
**Today:** `acpLiveState` has `.connecting`/`.connected`. Check whether the chat's status line distinguishes `initialize`, `authenticate`, `session/load` and the first `session/update`. If it does not, map those four awaited requests to status text in `currentACPSession`. A slow Claude Code cold start currently looks the same as a hung one.
**Built:** it did not. `IDEACPStartupStep` now sets the status from the request the start waits on: "Starting <agent>…" around `initialize` (process launch included), "Loading the <agent> session…" around `session/load`, "Starting a <agent> session…" around `session/new`, then back to "Thinking…" until the first output. Only while a run shows a status (an early start from the model picker sets nothing). Sign-in inside `connect`/`newSession` is not told apart. Test: `IDEACPTests.testTheStatusSaysWhichStartupStepASlowAgentIsOn` (the fake agent answers slowly in `slow` mode).

## 5. Tool cards still running after a disconnect (fixed 2026-11-24)

`handleClose` finishes calls that are waiting for approval. A tool call the agent reported as `in_progress` that was not waiting for approval is not in that set. Confirm that `IDEAgentConversation` marks such cards finished when `.runEnded(.failed)` arrives. If it does not, settle `knownToolCalls` whose status is not terminal in `handleClose` as well. This is T3's "terminal settlement must settle open tool calls".
**Confirmed and fixed:** the conversation settled approval, question and input cards at `.runEnded` but not plain tool cards, so a call the agent reported `in_progress` before disconnecting spun forever, also after a relaunch. `IDEAgentEntry.settlingUnfinishedCalls` now gives every unfinished tool card (not a plan card) an error outcome, "No result: the run ended before this call finished. It may have partly run.", at `.runEnded` and when a saved chat loads. Tests: `IDEACPTests.testAToolCallTheAgentNeverFinishedIsSettledWhenItDisconnects` (fails without the fix), `testSettlingLeavesFinishedCallsAndPlansAlone`.

## Not taken, on purpose

- **Remote access, mobile and web clients, guest links, push.** These need a long-running server that owns the work, and that conflicts with "no hidden network calls or background activity" (App Store rules in the root `CLAUDE.md`). Revisit only as a separate opt-in companion, not in the harness.
- **Outside agents over MCP** (Umbra as an MCP server for other agents). `UmbraACP` already exposes an `AgentSession` as an ACP agent. Serving MCP to unknown clients needs auth (T3 uses OAuth), so it waits for a user request.
- **Event-sourced orchestration** (pure decide, commit in one transaction, outbox worker). It pays off for a multi-client server. A single-window `AgentSession` with a checkpoint log and "repair unanswered calls on init" already gives the guarantee that matters: no half-recorded turn after a crash.
- **Voice input.** Not wanted (decision of 2026-11-24). Do not build voice capture or dictation into the composer.
- **Prompt links, device streaming, hosted source-control breadth.** These are product features, not harness. Track them in the product roadmap if wanted.

## Order

1. `agent-harness-10.md` phases 1 and 2: the biggest user-visible loss today.
2. Item 5 (check), then item 4: tiny.
3. Item 1: small, and visible.
4. Item 3: before the next managed-adapter version bump.
5. `agent-harness-10.md` phases 3 to 5, then item 2.

## Open questions

- Item 2: should a missed tick run on launch at all, or only be reported?
- Item 1: one view per project, or one for all projects? Chats are stored in per-project hash directories, so "all projects" means walking the store.
