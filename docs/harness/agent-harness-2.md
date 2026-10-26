# Harness gap 2: subagents that can do real work

Part of the series `agent-harness-1.md` to `agent-harness-7.md` (index: `README.md`). Checked against the code on 2026-10-26.

**Status:** open. Phase 0 is a bug fix and can land on its own.

## What exists today

- **Tools.** `task` (`Packages/AgentKit/Sources/AgentKit/Tools/TaskTool.swift`) and `explore` (`ExploreTool.swift`), both in every Code session's tool list.
- **Agent definitions.** `AgentDefinition` (`Skills/AgentDefinition.swift`) parses `name`, `description`, `tools` (a list), `mode` (`edit` or `write` means it edits; anything else is read-only), `max-iterations` (clamped to 1…60) and the body as instructions. **`model` is not read.** Files load from `<root>/.umbra/agents`, `<root>/.claude/agents`, `~/.claude/agents` (when user folders are enabled) and Application Support `agents` (`IDEAgentCommandCatalog.folders("agents")`), up to 50, with a built-in `general` last.
- **Child state.** `AgentSession` keeps `children: [String: Child]` and `childOrder`. Ids are `sub-` plus 8 hex characters; at most 12 are kept and the oldest idle one is evicted. Continuing a child (`session:`) fails with "sessions do not survive a relaunch" because `SessionSnapshot` has no children.
- **How a child is limited.** `AgentSession.childTools(for:)` drops every `.command` tool (so MCP tools too), keeps only `.read` tools for a read-only agent, then narrows to the agent's `tools` list. `withheldFromChildren` drops `ask_user, exit_plan_mode, todo, remember, explore, task, show_file`. `explore` uses a separate list (`childToolsForSubagent()`) and runs in plan mode.
- **Approvals are refused.** In `AgentSession.runChild`, a child's `.approvalRequested` is answered with `.deny(note: "A subagent cannot ask the user for approval …")`. `delegate` refuses an edit-capable agent unless the parent is in Accept Edits or Auto, and enforces one editing child at a time.
- **Events.** `AgentEvent.subagent(id:event:)` carries a child's events (`id` is the parent's tool-call id). `.subagentFinished(sessionID:agent:description:summary:ending:)` fires only for background children. `resolveApproval(callID:decision:)`, `answerQuestion(callID:answer:)` and `resolvePlan(callID:decision:)` look only in the parent's pending set.
- **Client and model.** A child uses `request.client ?? client` and `configuration.model`. `TaskTool.childClient` and `ExploreTool.childClient` are set only in tests. Umbra builds clients with `IDEAgentSettings.makeClient(for: IDEAIModelChoice, requiresTools:)` (through `IDEAgentConversation.choiceClientFactory`).
- **Umbra shows nothing special.** `IDEAgentEntry.Kind` has no subagent case. `IDEAgentConversation` ignores `.subagent` (a comment says a collapsible card "plugs in here") and turns `.subagentFinished` into a plain notice. `task` and `explore` show as generic tool cards (`IDEAgentToolSummary` has no entry for them). The only stop is `IDEAgentConversation.stop()`; `endChildren()` is private to `AgentSession`.
- **A bug the first version of this doc missed.** The child's `AgentConfiguration` does not receive `gate`, so `IDEAgentClaimsGate` (the cross-chat file claims) does not apply to a child's edits, despite the comment in `IDEAgentConversation` that mentions it. A child also gets no `snapshotter`, `afterEdit`, `cacheKey`, `policies` or budget settings.

## Gap

- A child cannot run commands or ask the user, so it cannot build, test or follow up on its own work.
- No `model` per agent. Delegating exploration to a cheap or local model is the main reason to have subagents.
- The user sees no child progress, cannot stop one child, and cannot continue one after a relaunch.
- A child's edits bypass the file-claims gate.

## What Claude Code and OpenCode do

- Subagents run commands and edit files under their own tool allow-list.
- An agent definition can pick its own model.
- A child's approvals appear in the parent's UI, labelled with the agent.
- Several children run in parallel, each visible and stoppable.

## Proposal

**Phase 0: pass the missing configuration to children.** Hand `gate`, `snapshotter`, `afterEdit` and `cacheKey` to the child configuration in `delegate` and in the `explore` path (`AgentSession.swift`, the two child `AgentConfiguration` blocks). Test: a file claimed by another chat makes a child's edit ask.

**Phase 1: approval routing.**
1. In `runChild`, stop auto-denying. The child's `.approvalRequested`, `.questionAsked` and `.planProposed` events already arrive wrapped as `.subagent(id:event:)`; forward them to the parent's consumer.
2. `resolveApproval`, `answerQuestion` and `resolvePlan` look in the parent's pending set first, then in `children` by call id, and call the child's own method.
3. Umbra handles a wrapped approval with the existing approval card, labelled with the agent name (`IDEAgentConversation`, where `.subagent` is ignored today).
4. Then remove the Manual-mode refusal in `delegate` and let `childTools(for:)` keep `.command` tools for edit-capable agents. Commands still ask; the one-editing-child rule stays.
5. A run that ends while a child waits on the user cancels that child (the same path `endChildren()` takes).

**Phase 2: model override.**
1. `model` (and optionally `provider`) in `AgentDefinition` frontmatter.
2. A new `AgentConfiguration.makeChildClient: (@Sendable (String) throws -> ChildClient)?`, where `ChildClient` holds the client, model id and context window. Umbra implements it with `IDEAgentSettings.makeClient(for: IDEAIModelChoice)`. An unknown or unavailable model falls back to the parent's and the tool output says so.
3. The agents catalog is already in the session fingerprint; the model field joins it.

**Phase 3: UI.**
1. A `.subagent` case in `IDEAgentEntry.Kind`: a collapsible card with the child's steps, tokens, state (running, background, finished, failed) and a Stop button.
2. `IDEAgentToolSummary` entries for `task` and `explore`.
3. `AgentSession.stopChild(id:)` (public), used by the card.

**Phase 4: persistence.** An optional `children` array in `SessionSnapshot` (`Session/SessionStore.swift`; Codable with a default so old files load) holding each child's id, agent, items and usage. `session:` continuation then works after a relaunch.

## Rules to keep

- Depth stays 1; a child's `task` answers with the depth limit.
- At most one edit-capable child runs at a time; read-only children are unlimited.
- Child tokens count toward the run budget, including background children.
- Revert Run covers a child's edits (it shares the parent's `CheckpointLog`).
- Anything a child reads from the web or MCP is untrusted, as in the parent.

## Tests

Extend `TaskToolTests` (`Packages/AgentKit/Tests`): the claims gate applies to a child edit (phase 0); an approval raised by a child reaches the host and resolves; a question from a child is answered; a child with a model override uses it and falls back when it is unknown; `stopChild` cancels one child and leaves the parent running; a child continues after a snapshot reload. Umbra side: a `.subagent` entry renders and Stop works (`IDEAgent*Tests`). Measure the model override with AgentEval at 5+ trials before claiming it helps.

## Done when

Two read-only children and one editing child run in one turn under `MockLLMClient`; the editing child's `run_command` shows an approval card labelled with its agent; stopping that child leaves the others and the parent running; with a real model, an agent that sets `model:` runs on it.

## Size

Phase 0: S. Phase 1: M. Phase 2: S. Phase 3: M. Phase 4: S.

## Open questions

- Should a background child's approval wait for the user indefinitely (like `ask_user`), or time out into a refusal?
- Should `model:` accept only ids the user already configured, or any id the active provider lists?
