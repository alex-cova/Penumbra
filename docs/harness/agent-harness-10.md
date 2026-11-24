# Harness gap 10: portable handoffs (context survives an agent switch)

Part of the series `agent-harness-1.md` to `agent-harness-11.md` (there is no index file; `ls docs/harness`). Checked against the code on 2026-11-24. Prompted by the T3 Code comparison (`docs/user/portable-handoffs.md` and `docs/internals/03_providers.md` in the T3 tree).

**Status:** phases 1 and 2 built 2026-11-24. `ConversationHandoff` (AgentKit, `Session/ConversationHandoff.swift`) and `IDEACPHandoff` (Umbra, the transcript → turns mapping) are wired into `IDEAgentConversation.acpPrompt`: after `unsupportedNotice`, `staleNotice` or `freshHistoryNotice` (now reworded to "Your next message brings the earlier conversation with it"), the next prompt is sent as two text blocks, handoff then message, once. Two deviations from the proposal: the handoff is always a text block (no `embeddedContext` resource yet), and activity is one "Used tools: …" line per run of tool calls in place, not extra outcomes from the omitted span. Tests: `ConversationHandoffTests`, `IDEACPHandoffTests`, `IDEACPTests` (`testStaleSessionStartsANewOneAndHandsOffTheTranscript`, `testSessionRestoreWithoutLoadSessionKeepsTheTranscript`, and the restored case, which must not hand off). **Phase 3 built 2026-11-24**, differently from the proposal in two ways. (1) No new `IDEACPSwitchEffect`: `.open` already opens or reuses the chat, and `IDEAgentController.selectProvider` now gives it the idle chat's conversation as `IDEAgentConversation.carriedTurns` (plus what that chat was itself carrying, so switching twice before sending loses nothing), with the notice "This chat uses X and continues “title”…" (`IDEACPHandoff.switchNotice`). A running chat carries nothing, as before. (2) A native target gets the handoff as text before the first message (`nativeHandoff`), not as `ConversationItem`s: it applies whenever a native session's history holds no message yet in a chat that already has some, which also covers AI mode's picker switching a chat from an ACP agent to a native model in place (ACP → ACP in place was already covered by phase 2, since a changed launch fingerprint drops the saved session id). `carriedTurns` is not saved: the new chat is empty until its first message. Test: `IDEACPTests.testSwitchingAnIdleACPChatToNativeCarriesItsConversation`. Phases 4 and 5 are open.

## What exists today

- **Native chats keep their history across model changes.** `ConversationItem` is Umbra's own format, so a native chat can move between OpenAI, Anthropic, Ollama, MLX and Apple models and the next request carries the whole transcript.
- **ACP chats lose context in four places.** `IDEACPSessionResume` (`Umbra/Sources/Umbra/Agent/ACP/IDEACPRegistry.swift`) ends each of these notices with "Earlier messages were not sent again":
  - `unsupportedNotice`: the agent does not advertise `loadSession`.
  - `staleNotice`: `session/load` failed (the agent pruned the session, or the adapter was reinstalled).
  - `freshHistoryNotice`: a transcript exists but no session id was saved.
  - `restoredNotice`: the only case where the agent itself still has the context.
- **Switching agents never carries context.** `IDEACPProviderSwitch.plan` returns `.open` for any chat with a transcript, and `IDEAgentController.selectProvider` opens an empty chat with "This chat uses X. Y stays in its own chat." Going from native to ACP, ACP to native, or Claude Code to Codex starts from nothing.
- **ACP chats cannot be forked or rewound.** `supportsAgentKitOnlyFeatures` is false for ACP (`IDEAgentConversation.swift:249`), and `fork(_:before:)` copies `ConversationItem`s, which an ACP chat does not have.
- **Building blocks already in place:** `ContextEstimate.tokens(_:)` (`ContextCompaction.swift`), the `IDEAgentEntry` transcript with `.user`/`.assistant`/`.toolCall` kinds saved for every chat including ACP, `ACPPromptCapabilities.embeddedContext`, and `ACPClientSession.send(prompt:)` taking several content blocks.

## Gap

When the agent behind a chat changes, or loses its own memory, Umbra keeps the transcript on screen but the model sees none of it. The user has to restate everything, usually without noticing that they need to.

## What T3 does

- A **handoff** is a budgeted selection of saved messages, not a summary written by the agent. The original request and the most recent turns are always kept. Each message keeps its full text, its role and its order, including partial answers from failed turns. The outgoing agent's reasoning, tool-call state and attachments are left out.
- The new request stays separate and is **never shortened** to fit. If it does not fit, the user is asked to shorten it or pick a larger window.
- References to omitted history are included, and a **thread-reading tool** lets the agent fetch the rest on demand.
- Budget: 16K tokens by default (clamped to 1K–64K). It reserves max(16K, window/4) for instructions, tools and later work, and assumes a 128K window when the window is unknown. Accounting is conservative: 1 token per UTF-8 byte.
- The same mechanism covers a provider switch, a fork the provider cannot do natively, a restart where the provider lost the session, and migrated threads.

## Proposal

**Phase 1: `ConversationHandoff` in AgentKit (pure, no I/O).**
- Input: transcript turns (role, text, an optional tool-outcome line), the target window or nil, a token cap, and the size of the pending request.
- Output: the selected turns, the ids of the omitted ranges, and a rendered block, for example `<earlier-conversation omitted="12 messages; use read_conversation">…</earlier-conversation>`.
- Selection order: first user message, then newest turns going backwards, then one-line outcomes of commands and tests from the omitted span. Messages are kept whole; a message too large for the budget is cut at the end and gets an omission reference.
- Estimate conservatively (bytes, not bytes/4), because the target's tokenizer is unknown.
- Unit tests only.

**Phase 2: use it where Umbra now says "Earlier messages were not sent again".**
- In `IDEAgentConversation`, the `.create(notice:)` branch with `hasEarlierTranscript` builds a handoff from `entries` and sends it with the next user prompt.
- Delivery: as an `embeddedContext` resource block when the agent advertises it, otherwise as a leading text block.
- Change the notices to say what was sent, for example "Sent the last 9 of 21 messages to the new session."

**Phase 3: switching agents carries the chat.**
- `IDEACPProviderSwitch.plan` gains a `.handoff` effect. It applies when the selected chat is idle and has a transcript.
- Umbra opens a new chat bound to the target. The new chat shows a "Continued from <chat>" notice and seeds its first request with the handoff.
- Native to native keeps today's behaviour (same chat, full items). For a native target, the handoff becomes `ConversationItem`s with user and assistant roles.
- The old chat stays as it is. A running chat still refuses the switch, as now.

**Phase 4: `read_conversation` tool.**
- A read-only native tool over the saved transcript of the current chat and of the chat it was continued from. It takes a range or a search query and pages through `read_tool_output`.
- Omission references in the handoff name it.
- For ACP targets, see the open question below.

**Phase 5: fork and rewind for ACP chats.**
- Fork builds a new ACP session seeded with the handoff up to the chosen entry.
- Rewind applies only to files (the checkpoint log already covers ACP runs). The conversation is never rolled back silently: following T3's rule, refuse before touching files when the conversation cannot follow. The UI offers "revert files and start a new session with the handoff" instead.

## Rules to keep

- The user's new message is never truncated or merged into the handoff block.
- A handoff is attributed text, not instructions. Wrap it so the agent can tell earlier turns from the new request.
- Nothing is sent to an agent the user has not consented to. The handoff goes through the same send-consent path as a normal prompt.
- Secrets: run the selection through the same scrubbing as `/export json`.
- Byte-stable output (the same transcript gives the same block), so the prompt cache survives a retry.

## Tests

- `ConversationHandoffTests` (AgentKit): budget edges, first message always kept, an oversized message cut with a reference, no window → 128K assumption, a request that does not fit → error, not truncation.
- `IDEACPSessionResumeTests`: each `.create` path with a transcript produces a handoff.
- An ACP fixture agent that records the prompt blocks it received.

## Done when

Switching a chat from Claude Code (ACP) to a native model, or reopening an ACP chat whose session was pruned, lets the model answer "what did we decide earlier?" correctly without the user pasting anything.

## Size

Phase 1: small. Phases 2 and 3: medium (mostly `IDEAgentConversation` and `IDEAgentController`). Phase 4: small. Phase 5: medium.

## Open questions

- **`read_conversation` for ACP agents.** ACP agents only see Umbra tools through MCP. Either serve one small MCP server from Umbra (stdio, through `UmbraACP`?), or ship without retrieval for ACP and rely on the budgeted selection.
- **Default cap.** T3 uses 16K tokens. Umbra's local models have 8–32K windows, so the cap should scale with the window (for example min(16K, window/4)).
- Should tool outcomes be included for a native target as real `toolCall`/`toolResult` items? This would need a matching tool list, so the proposal says no: send them as text.
