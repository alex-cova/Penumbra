# Harness gap 8: local models as helpers for hosted ones

Part of the series `agent-harness-1.md` to `agent-harness-8.md` (index: `README.md`). Checked against the code on 2026-10-26.

**Status:** open. Needs `agent-harness-2.md` phase 2 (per-agent model); phase 1 below is that phase plus a setting, so the two can land together.

## What exists today

- **Clients per choice.** `IDEAgentSettings.makeClient(for: IDEAIModelChoice, requiresTools:)` builds OpenAI, Anthropic, Ollama, MLX, Apple and ACP clients; `IDEAgentConversation.choiceClientFactory` calls it. A chat has one model (`IDEAIModelChoice`, nil = global settings).
- **Children share the parent's model.** `AgentSession.runSubagent` and the `task` path build the child with `request.client ?? client` and `model: configuration.model`. `TaskTool.childClient` and `ExploreTool.childClient` are set only in tests. `AgentDefinition` does not read `model` (see `agent-harness-2.md`, "What exists today").
- **Summaries use the parent's model.** `AgentSession.summarize` builds its `LLMRequest` with `configuration.model` and the session's client (`Session/ContextCompaction.swift` holds the prompt and the cut). With `cacheFriendlySummaries` the request reuses the session prefix, so it must stay on the same model.
- **Titles are not model-written.** `IDEAgentConversation.title(fromMessage:)` and `SessionStore.title(from:)` derive a title from the first user message. No model call to replace.
- **Local models are weaker for tool use.** AgentEval (session notes, not saved: `agent-harness-7.md` item 1): a 27B Ollama model about 7/8, Qwen2.5-7B on MLX 3/16, a 3B 0/16. `IDELocalModelFilter` already filters Ollama models by tool support.
- **Usage and price.** Child tokens join the parent run's budget (`TokenUsage`). `IDEAgentPrices` holds an editable price table by model id.

## Gap

- No way to run any part of a session on a cheaper or local model; every `explore`, summary and `task` is billed at the hosted rate.
- A hosted model cannot call a local model on purpose, and the user cannot say "read this with the local model".
- Usage is not tagged by model, so a mixed run cannot show what the local part saved.

## Design

Two directions, one mechanism: **a child can run on another model**.

- **Cheap work goes down.** The host picks a *helper model* for chores whose output a wrong answer barely hurts: `explore`, compaction summaries, tool-output summaries.
- **Local models are offered up.** The hosted model can hand a bounded task to a named local agent through `task`; its description says what the agent is good for and that the result must be checked.

Automatic routing of the main turn is **out of scope**: sending a hard turn to a weak model costs more than it saves. Routes stay explicit (the helper setting, a named agent, a slash command).

## Proposal

**Phase 1: model override and a helper model** (includes `agent-harness-2.md` phase 2).
1. `AgentDefinition.model: String?` from frontmatter `model:`. Values: an id the host understands (`ollama:qwen3-coder:30b`, `mlx:<repo>`, `anthropic:claude-haiku-5-5`), or `helper` for the setting below.
2. `AgentConfiguration.makeChildClient: (@Sendable (String) throws -> ChildClient)?`; `ChildClient` holds client, model id and context window. `runSubagent` and the `task` path use it when the agent (or `explore`) names a model; an unknown or unavailable one falls back to the parent's and the tool output says so.
3. Umbra: a **Helper model** setting in Agent Settings (an `IDEAIModelChoice`, default none), used for `explore` when set and by agents that say `model: helper`. The choice and the agents catalog join the session fingerprint.
4. Summaries stay on the parent's model while `cacheFriendlySummaries` is on. Add `AgentConfiguration.summaryClient` only for the non-cache path (tool call or forced overflow pass in `summarize`), behind the same setting.

**Phase 2: capability gate.**
1. A helper model is accepted only when it supports tools (`IDELocalModelFilter` for Ollama; the MLX catalog's tool flag) and its window is at least a floor (start at 16K; the 6 KB `explore` report and 15 iterations need room).
2. A model that fails the gate shows why in Settings and is not offered; a saved choice that stops passing (model deleted) falls back to the parent's model with a one-line notice.

**Phase 3: agents the hosted model can choose.**
1. Built-in `local-explore` (read-only, `model: helper`, the `explore` tool list) and `local-digest` (read-only, `read_file`/`grep` only, instructed to return quotes with `path:line` and no conclusions). Listed in the `task` description only when a helper model is set and passes the gate.
2. Their descriptions tell the hosted model when to use them (bulk reading, finding call sites, summarizing a large file) and that the output is unverified.
3. Optional: a `/local <prompt>` command that runs one prompt on the helper model in a child and pastes the report into the chat.

**Phase 4: accounting.**
1. Tag child usage with the model id that produced it (`TokenUsage` per model, or a `model` field on the `.subagent` usage event).
2. `IDEAgentPrices`: local ids are priced at 0, and the cost estimate shows hosted cost only. The run summary lists tokens kept off the hosted model.

**Phase 5 (decide later): escalation and external callers.**
1. A local child that reaches its iteration cap or returns no usable text hands the task back; the tool output says "the helper model could not finish; do this yourself" so the hosted model continues.
2. Expose the helper model as an MCP server or ACP agent so tools outside Umbra can call it. A network-facing listener, so opt-in and local-only if built.

## Rules to keep

- Helper models are read-only unless the user names an editing agent with `model:` themselves; an editing child on a weak model is the user's explicit choice.
- Output from a helper is data to the hosted model, wrapped as untrusted like any child report.
- Nothing is downloaded or started for the helper without the user choosing it; no hidden network calls (App Store rules). Ollama is the user's own server; MLX uses the existing download sheet.
- One MLX model resident at a time: a helper on MLX while the parent is also MLX uses the same model, or the call is refused with the reason (a second resident model competes for memory).
- `AgentKit` stays Foundation-only; only the host knows what `ollama:` or `mlx:` means.

## Tests

`TaskToolTests` style with `MockLLMClient`: a child with `model:` uses the resolved client and model id; an unknown id falls back and says so; `model: helper` with no helper set falls back; `explore` uses the helper when set. `AgentDefinitionTests`: `model:` parses and joins the fingerprint. Umbra: the capability gate rejects a no-tools model and a small window; a deleted saved model falls back with a notice. Accounting: a mixed run reports hosted and local tokens separately and prices local at 0.

**Measure before keeping phase 3.** Run AgentEval's exploration-style tasks with `explore` on the hosted model and on each candidate local model, 5+ trials each, saved under `Tools/AgentEval/Results/` (`agent-harness-7.md` item 1). Report wrong or missing answers, not only pass rate. If no local model reaches the hosted model's rate, ship phase 1 and the gate only, and leave `local-*` agents out.

## Done when

With a helper model set, an `explore` call under `MockLLMClient` runs on it and its tokens show as local; with a real hosted model and a 27B-class Ollama helper, a codebase question is answered with the file reading done locally and the hosted request count lower than before, measured.

## Size

Phase 1: S to M (shares work with plan 2 phase 2). Phase 2: S. Phase 3: S. Phase 4: S. Phase 5: M, undecided.

## Open questions

- Should `explore` use the helper by default whenever one is set, or only when the user opts in per chat?
- Is a tool-capable window floor of 16K right? Check against the `explore` report size and measured runs.
- Does a hosted-model chat (Anthropic or OpenAI) that delegates to a local model need a first-use confirmation, since the local report then goes back into a hosted conversation? (File contents that `SecretFilePolicy` blocks never reach the child either way.)
