# Harness gap 9: Muse (Meta) as a first-class provider

Part of the series `agent-harness-1.md` to `agent-harness-9.md` (there is no index file; `ls docs/harness`). Checked against the code and against the live API on 2026-11-02.

**Status:** all six phases built or measured 2026-11-02. Phases 1 and 2: the four things that were wrong, pinned against the real API. Phase 3: the 1,048,576-token window and the overflow error are measured, prices and limits are checked against Meta's rate sheet. Phase 4: rate limits reach the retry status line. Phase 5: the 14-task suite ran on the production id, with a reasoning sweep and `muse-wonder-1.0`. Phase 6: reasoning summaries stream and are shown as the status line. What stays open is under *Open questions*. **`muse-spark-1.3-contributor` is out of scope for now** (decision of 2026-11-02): nothing below builds, measures or special-cases it. It stays selectable and priced as before, and the 2026-10-29 eval files that used it are history, not a baseline for the production id.

## What exists today

- **Provider.** `IDEAgentProvider.meta` (`Umbra/Sources/Umbra/Agent/IDEAgentSettings.swift`), default model `muse-spark-1.3`, base URL `https://api.meta.ai/v1`, key in the Keychain per host. Driven by `OpenAIResponsesClient` (Responses format, Bearer key). Hosts build it through `OpenAIResponsesClient.meta(...)` (AgentKit): Umbra's `IDEAgentClientFactory`, `UmbraAgentProviderFactory` (`umbra-agent`, `UmbraACP`) and AgentEval's `Providers`.
- **Picker.** `IDEAIModelPicker.metaSection` lists `IDEAgentSettings.offeredMetaModels`: what `GET /v1/models` returns (`HostedModelCatalog`), filtered to chat models, else the shipped ids in `IDEAIModelNames.muse`.
- **Cost and window.** `IDEAgentPrices` rows `muse-spark` and `muse-wonder-1.0` (checked against Meta's rate sheet, `testTheMusePriceRowsMatchMetasRateSheet`) and a 1,048,576-token window for the prefix `muse-` in `hostedContextWindows` (measured, `MetaSmokeTests.anOversizedPromptIsRejectedAsContextOverflowAtTheAssumedWindow`). The `-contributor` rows are left as they were.
- **Evals.** `Tools/AgentEval/Results/2026-10-29-*-muse-spark.json` (14 tasks × 5; all with `muse-spark-1.3-contributor`): baseline 65/70, no-line-numbers 68/70, announce-nudge 69/70. The production id has its own runs from 2026-11-02, summarised under *Measured on the production id*.
- **Tests.** AgentKit `MetaSmokeTests` (opt-in, `AGENTKIT_META_KEY`), `HostedModelCatalogTests`, `MetaClosingTurnTests`; Umbra `IDEAIModelChoiceTests`, `IDEAgentProviderTests`, `UmbraAgentCLITests`.

## What the API does (probed 2026-11-02, `muse-spark-1.3`)

Pinned by `MetaSmokeTests` where a test can pin it. If one of those fails, Meta changed the API.

| Question | Answer | Consequence in the harness |
|---|---|---|
| `tool_choice: "none"` | 400: "only `auto` is supported" | `OpenAIResponsesClient.meta` has `supportsDisabledToolChoice == false`: a closing turn (iteration cap, budget stop) sends no tool list instead of `none`. Before this, such a run would have failed with a 400. |
| `reasoning.effort` | `none` is a 400. Valid: `minimal, low, medium, high, xhigh, max`. The model always reasons (a one-word answer used 15 to 280 reasoning tokens across the models and efforts probed). | `IDEAgentProvider.meta.reasoningEfforts` is `minimal…max`, default `medium`, no "off". A saved "off" reads as the default (`normalizedReasoning`). |
| `GET /models` | Also lists `muse-image-1.0`, `muse-voice-transcribe-1.0`, `sam-3.1` (and the `-contributor` ids) | `IDEAIModelNames.isMuseChatModel` drops image, voice, transcribe, audio, speech and embed models and anything not starting `muse-`. An exclusion list on purpose, so a new Muse chat model still appears. |
| Image input | Accepted: `input_image` with a data URL; a solid red picture came back as "Red" | `supportsImages` stays true for the Responses client. |
| Prompt cache | Automatic; `prompt_cache_key` accepted; 3,939 of 4,014 input tokens cached on the second call | `cachedInputTokens` is parsed from `input_tokens_details` already. |
| Non-strict raw schemas (MCP) | Accepted | none |
| Unknown model | 404, `code: model_not_found`, "The requested model was not found." | `HTTPErrorClassifier` reports `badRequest(404, …)` and the UI shows that sentence (`MetaErrorBodyTests`); clear enough, so no new error case. |
| Context window | 400, `code: context_length_exceeded`: "The input (3584471 tokens) exceeds the model's context window of 1048576 tokens." Rejected before generation, so it costs nothing | The classifier's needle `context_length_exceeded` already maps it to `LLMError.contextLengthExceeded`, which forces compaction. The assumed window was right. |
| Reasoning summary | `reasoning.summary: "auto"` streams the OpenAI events `response.reasoning_summary_part.added` / `…_text.delta` / `…_text.done`; the finished reasoning item holds `summary` parts and `encrypted_content` | `ResponsesEventDecoder` already read the deltas; it now separates parts with a paragraph break, and Umbra shows the latest line in the status (phase 6). |
| Rate limits | Headers `x-ratelimit-{limit,remaining}-{requests,tokens}`. Meta's rate sheet (dev.meta.ai/docs/pricing-rate-limits, read 2026-11-02): per team, not per key, per minute; 3,000 requests and 4,000,000 tokens for Spark 1.1 to 1.3 and Wonder | Parsed into `RateLimitStatus`; a retry says which limit ran out (phase 4). |
| `max_output_tokens` | Counts reasoning: a 300-token cap on `xhigh` ended with no answer (`incomplete_details.reason = max_output_tokens`) | Umbra leaves it unset (the window is 1M), so this only bites a host that sets a small cap; the cut-off path in `AgentSession` already continues. |

## Gap (what was open, and where it ended)

- **The window and the overflow error were guesses.** Now measured; see phase 3.
- **Rate limits were invisible.** Now named in the retry status; see phase 4.
- **Evals covered the wrong id.** Now run on the production id; see phase 5.
- **Reasoning was not shown.** Now shown as the status line; see phase 6.

## Proposal

**Phase 1: what was wrong (built 2026-11-02).**
1. `OpenAIResponsesClient(supportsDisabledToolChoice:)` and `.meta(...)`; the four call sites use it. Tests: `MetaClosingTurnTests` (flags; a run that hits its cap sends no `tool_choice` and no tools on the last turn), `MetaSmokeTests.toolChoiceNoneIsStillRejected` and `theClosingTurnOfACappedRunWorksWithoutToolChoiceNone`.
2. `isMuseChatModel` applied in `refreshMetaModels`. Test: `IDEAIModelChoiceTests.testMetaNonChatModelsAreLeftOutOfThePicker` with the captured list.
3. Meta's reasoning efforts. Tests: `testMuseOffersMinimalToMaxAndNeverSendsOff`, `MetaSmokeTests.reasoningNoneIsRejectedAndMinimalToMaxAreAccepted`.
4. Output budget: no change needed (see the table); recorded here so nobody adds a cap that starves the answer.

**Phase 2: pin the wire (built 2026-11-02).** `MetaSmokeTests` gained image input, `tool_choice: none`, reasoning `none` versus `minimal/low`, a repeated prefix reporting cached tokens, and a capped run. 8 tests, all passing against the live API on 2026-11-02 (a few cents). Key names differ on purpose: `AGENTKIT_META_KEY` is refused in CI by `Scripts/refuse-paid-test-variables.sh`; `META_API_KEY` is what `umbra-agent` and AgentEval read; Umbra reads the Keychain.

**Phase 3: the window and the errors (built 2026-11-02).**
1. One oversized request (about 6 MB of hex) was rejected with `context_length_exceeded` and the sentence quoted in the table, naming a window of exactly 1,048,576 tokens. It cost nothing. `MetaSmokeTests.anOversizedPromptIsRejectedAsContextOverflowAtTheAssumedWindow` repeats it, and `MetaErrorBodyTests` pins the three captured error bodies (overflow, unknown model, rejected `tool_choice`).
2. Prices: read from Meta's rate sheet (https://dev.meta.ai/docs/pricing-rate-limits, 2026-11-02): Spark 1.1 to 1.3 at $1.25 input / $0.15 cached / $4.25 output per million tokens, Wonder at $4.00 / $0.20 / $20.00. The app's rows match; `testTheMusePriceRowsMatchMetasRateSheet` pins them.
3. The 404 wording is already clear (see the table); no change.

**Phase 4: rate limits (built 2026-11-02).** `RateLimitStatus.parse(headers:)`; `LLMEvent.rateLimit` first in a stream whose response had the headers and before `.retrying` for a failed one; `AgentEvent.rateLimit`; Umbra keeps the latest and `IDEAgentToolSummary.retryStatus` says "The provider's requests rate limit is used up. Retrying in 12 s (try 1)…" when a limit is spent. Tests: `RateLimitStatusTests`, `IDEAgentRetryStatusTests`. Two parts of the original proposal were dropped on purpose: a Settings line (it would only show what the last run saw) and bounding parallel children by the remaining count. The production ids allow 3,000 requests a minute per team and one agent run makes a few dozen, so the limit matters only for several busy windows at once; revisit if that is seen.

**Phase 5: evals on the production id (done 2026-11-02, about $17 at the rate sheet's prices: five arms, 70 trials each except Wonder at 42, then Spark 1.2 and 1.1 at 42 each).** See *Measured on the production id* below.

**Phase 6: show the reasoning (built 2026-11-02).** The premise in the first version of this doc, "as for Claude's summarized thinking", was wrong: Umbra's Code chat dropped `.reasoningDelta` for every provider. Now `IDEAgentConversation` shows the latest line of the streamed summary in the status ("Thinking: Verifying the total."), reset when the answer starts or a new turn begins; nothing is added to the transcript, and it works for Claude and OpenAI as well. A collapsible "Thinking" disclosure in the transcript is a larger UI change and is not built. Tests: `ResponsesEventDecoderTests.summaryPartsAreSeparatedByAParagraphBreak` (the shape captured from Meta), `IDEAgentEntryPointsTests`.

## Rules to keep

- Meta is reached only when the user picked it, after the usual per-host "Allow Sending". Nothing here adds a call: the model list is fetched when the picker opens with a saved key, as before.
- The key stays in the Keychain, in the environment of a CLI run, or on a command line the user typed; never in a transcript, a log, a result file or this repository. Result files are checked for the key before they are saved.
- A provider quirk lives in one place (`OpenAIResponsesClient.meta`, `IDEAgentProvider`), has a smoke test, and is written in the table above.
- `-contributor`: do nothing until the owner says so.

## Measured on 2026-11-02: hosted baseline for `agent-harness-8.md`

`agent-harness-8.md` says to measure `explore`-style reading on a hosted model beside each local candidate before keeping phase 3. Same two tasks (`find-callers`, `trace-default`), 5 trials each, full toolset, one run per model (`Tools/AgentEval/Results/`):

| Model | Passes | Input tokens / trial | Output tokens / trial | Seconds / trial | Tool calls / trial |
|---|---|---|---|---|---|
| Muse Spark 1.3 (`2026-11-02-helper-read-muse-spark-1.3.json`) | 10/10 | 32,234 (21,938 cached) | 2,205 | 25 | 8.9 |
| Qwen 27B on Ollama (`2026-10-26-helper-read-27b.json`) | 10/10 | 18,753 | 434 | 27 | 6.8 |
| `qwen-fixed` on Ollama (`2026-10-26-helper-read-qwen-fixed.json`) | 10/10 | 19,090 | 504 | 35 | 7.8 |

No trial gave a wrong or missing answer on any model: the checks passed, and the final messages name the callers and the default. Reading: on these two tasks a local helper matches the hosted rate while reading about 40% fewer input tokens (and far fewer output tokens, since Muse also spends tokens on reasoning), so the doc's rule ("if no local model reaches the hosted model's rate, ship phase 1 and the gate only") does not trigger. Two tasks on one small project is thin evidence; the `local-*` agents stay, with the claim limited to that, until a larger exploration set exists. At the price table's rates a Muse Spark 1.3 trial cost about $0.03.

## Review of `c133a7fa..HEAD` against `docs/harness` (2026-11-02)

What the review found, and what was done about it.

| Finding | Done |
|---|---|
| MCP HTTP transport sent no `MCP-Protocol-Version` and ignored a 404 for an expired session (`agent-harness-1.md`) | Fixed: header on every request after `initialize` and on the `DELETE`; a 404 for a known session closes the transport so `MCPHub` restarts it. Tests in `MCPHTTPTransportTests`. Not yet tried against a strict hosted server. |
| A `task` child that edits ran in Accept Edits whatever the chat's mode, so Manual did not ask about a child's edits; `anEditingChildRunsWhereTheUserApprovesEachEdit` ran under `.approveAll`, which skips the policy, so it could not see it (`agent-harness-2.md` phase 1) | Fixed: the child follows the parent's mode, also after `setMode`/`setRules` and when restored. Tests: `aManualParentMakesAnEditingChildsEditsAsk`, `aChildContinuedAfterSwitchingToManualAsksAboutItsEdits`. |
| `8a8b76e3` moved cost booking from `.usage` to `.usageDetailed` and left `IDEAgentEntryPointsTests.testCostIsEstimatedPerTurnSavedAndRestoredAndLocalModelsHaveNone` sending `.usage`, so it failed (found by the 784-test agent/AI/MCP run of this review; the only failure) | The test now sends `.usageDetailed`; 12/12 pass. |
| Phase 3 of `agent-harness-8.md` shipped without the hosted baseline it demands | Measured (table above). |
| `agent-harness-7.md` §1 reported 21/42 for tolerant arguments with no baseline | The claim is corrected in that doc; the A/B (a strict-mode switch in AgentEval, two runs of `qwen-fixed`) is **not done**. |
| `README.md` and `BUILT.md` deleted but still linked from five files; every doc said "index: README.md" | Links and headers fixed. |
| Status lines of docs 2, 4, 7 and 8 said "open" or "decision needed" for built work; doc 1 lacked the review's additions; `Packages/AgentKit/CLAUDE.md` and `Umbra/.../Agent/CLAUDE.md` still described refused child approvals and ignored `.subagent` events | Updated to the code. |

## Measured on the production id

14 tasks × 5 trials, full toolset, `--jobs 4`, one run per arm (`Tools/AgentEval/Results/2026-11-02-*.json`; tokens are the means per trial, cost is at the rate sheet's prices):

| Arm | Passes | Failures (all ended `completed`) | Nudges | Input / output tokens | Turns | Seconds | Cost / trial |
|---|---|---|---|---|---|---|---|
| `muse-spark-1.3`, medium, nudge off (`baseline-muse-spark-1.3`) | 66/70 | `extract-duplicate`, `fix-config-key`, `read-large-file`, `rename-across-files` (1 each) | 0 | 57,954 / 1,544 | 8.8 | 18 | $0.035 |
| medium, nudge on (`nudge-muse-spark-1.3`) | 69/70 | `find-callers` (1) | 5 | 59,374 / 1,631 | 9.1 | 19 | $0.035 |
| minimal, nudge on (`effort-minimal-muse-spark-1.3`) | 70/70 | none | 2 | 42,376 / 946 | 7.0 | 12 | $0.028 |
| high, nudge on (`effort-high-muse-spark-1.3`) | 67/70 | `extract-duplicate` (2), `injection` (1) | 3 | 62,079 / 1,670 | 9.3 | 20 | $0.036 |
| `muse-wonder-1.0`, 14 × 3, medium, nudge on (`muse-wonder-1.0`) | 42/42 | none | 0 | 55,251 / 1,403 | 9.1 | 23 | $0.105 |
| `muse-spark-1.2`, 14 × 3, medium, nudge on (`muse-spark-1.2`) | 42/42 | none | 0 | 54,386 / 1,984 | 9.1 | 12 | $0.031 |
| `muse-spark-1.1`, 14 × 3, medium, nudge on (`muse-spark-1.1`) | 42/42 | none | 0 | 44,603 / 1,432 | 7.2 | 7 | $0.026 |

What it says:
- **The announce-nudge helps on the production id too.** 66/70 without it, 69/70 with it, as on `-contributor` (65 to 69). Umbra turns it on for Code chats; that stays.
- **Reasoning effort does not buy passes on these tasks.** 66 to 70 of 70 across `minimal`, `medium` and `high` is inside what 5 trials per task can resolve. `minimal` used about 30% fewer input tokens, 40% fewer turns and 35% less time than `medium` and `high`, and no more failures. The tasks are small Python projects, so this says nothing about work that needs long reasoning.
- **Every non-contributor model the picker offers does tool work.** Wonder, Spark 1.2 and Spark 1.1 each passed 42/42 with no failures, so none needs a chat-only mark in the Code picker. Wonder costs about three times a Spark trial; 1.1 and 1.2 are a little cheaper and quicker than 1.3 on these tasks (one 3-trial run each).
- **The default is now `minimal` for Muse (changed 2026-11-03).** The condition above was met by a second sweep on harder tasks (below). Saved choices are untouched: only a chat that never picked a level changes (`IDEAgentProvider.defaultReasoning`, pinned in `testMuseOffersMinimalToMaxAndNeverSendsOff`). OpenAI and Claude keep `medium`.

**Hard tasks, 2026-11-03** (`Tools/AgentEval/TasksHard/`, four tasks written for this and not part of the 14: `merge-bookings` (four bugs over two modules), `ttl-cache` (four bugs over a cache and its service), `discount-order` (two bugs in modules the test never imports), `registry-refactor` (module-level state replaced by an object passed through four callers); each validated to fail untouched and pass with its reference solution). `muse-spark-1.3`, nudge on, 8 trials per task, `--jobs 4`, `Results/2026-11-03-hard-effort-<effort>-muse-spark-1.3.json`:

| Arm | Passes | Input / output tokens | Turns | Seconds | Cost / trial |
|---|---|---|---|---|---|
| minimal | 32/32 | 40,425 / 1,724 | 8.7 | 16 | $0.027 |
| medium | 32/32 | 86,436 / 4,049 | 13.2 | 35 | $0.052 |

Both arms passed everything, so the sweep **cannot show that `minimal` is as good on work that needs long reasoning**, only that it was not worse on four multi-bug, multi-file tasks and used about half the tokens and time. Across both sweeps `minimal` passed 102 of 102 and `medium` 101 of 102. `low`, `high` and `xhigh` were not run on the hard tasks: with every arm at the ceiling another pass count would not move the default. A task `minimal` fails and `medium` passes is what would change it back; the reasoning menu still offers every level.

## Done when

Met on 2026-11-02, for every Muse model except the `-contributor` ids. The owner settled the scope on 2026-11-02, when asked whether the criterion should count them: it excludes them ("don't work on -contributor, for now" stands; they appear in the live picker list, and they stay unmeasured and unmarked until that is lifted, at which point `muse-spark-1.3-contributor` and `muse-spark-1.2-contributor` each need a 14 × 3 run like the others): the window and its overflow error are measured and mapped to compaction; the price rows cite Meta's rate sheet and a test pins them; a rate-limited retry says which limit ran out; the default reasoning was weighed against a sweep saved under `Tools/AgentEval/Results/`; every other Muse model the Code picker offers has a tool-use result of its own (Spark 1.3, 1.2, 1.1 and Wonder). The only result the `-contributor` ids have is the 2026-10-29 run on `muse-spark-1.3-contributor`.

## Size

All six phases: done.

## Open questions

- Is there a task where `minimal` fails and `medium` passes? The four hard tasks (2026-11-03) all passed on both; the next step is a harder set (a failing test that needs reading five modules, a refactor with a type change), and `low` and `xhigh`, which were not run.
- A collapsible "Thinking" disclosure in the transcript, for every provider that streams a summary, would be the proper home for what phase 6 only shows as a status line.
- The `-contributor` ids (parked by decision): the request limit on them is 150 a minute against 3,000, and they are priced at $0.10 / $0.002 / $0.20; a cheap hosted helper for a dearer main model is the obvious use.
- Does Meta expose its limits, window and prices through the API, so the harness need not carry tables? The rate sheet is a web page only.
