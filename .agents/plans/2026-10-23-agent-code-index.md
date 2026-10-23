## Goal

Give Umbra's agent CodeGraph-style one-call code understanding on top of the existing deep indexes, so the model stops crawling with `grep`/`read_file` and answers from the index. Today `go_to_definition` / `find_usages` need path + line + identifier, so the model must grep before it can use them.

## Success Criteria

- A model that knows only a type or method name reaches its declaration, members, implementations and usages in 1–2 tool calls, without a prior file path.
- Existing `go_to_definition` / `find_usages` flows keep working; no prompt regression on tasks that already succeed.
- Index-freshness failures are explicit to the model instead of silent wrong answers.
- The tool list and system prompt stay inside the existing token budgets (`IDEAgentTests.testTheToolsAndSystemPromptStayWithinTheirBudget`).

## Approach

Keep Umbra's semantic edge and borrow CodeGraph's packaging: one name search (`find_symbol`) and one entry (`explore_symbol`), both thin wrappers over what the palette and the navigation engine already use. No new index, no new language engine, no persistence change.

Reviewed against the code, the first draft changed like this:

- Name search reuses `JavaIndex.classes(matching:)` / `members(matching:)` (the ⌘O and Symbols searches, camel-hump ranked) and `SwiftIndex` / `TypeScriptIndex.symbols(matching:limit:)`. `JavaNameIndex` lists candidate *files* for usages, not declarations, so it is not used.
- One `find_symbol` instead of `find_type` + `workspace_symbol` (same data; two names recreate the tool-pick problem).
- No hover call: verbatim declaration lines (doc comment, annotations, signature) carry the signature and Javadoc in every language. Members come from the language-agnostic `StructureProviding` (`languages.structure(for:)`), not `JavaStructureProvider` directly.
- Staleness is measured, not assumed: every hit is located in the live text (open buffer, else disk), a hit that moved is flagged, and the "still building" banner comes from `IDEJavaSupport.status.message`. `JavaSharedShardHub` stamps cover JDK and jar shards, not project edits.
- Resident context is the real risk, so output is capped per section instead of leaning on `IDEAgentToolOutputs`. Callees are out of v1 (no engine-level API); implementations and usages (callers) are in.
- The blocked-tool A/B harness is replaced by deterministic tests plus a tool-cost check: `Tools/AgentEval` runs Python tasks without Umbra's tools, and real-model runs cost money.

Rejected: vendoring CodeGraph or its Rust kernel (duplicates the index, loses generics, `javac`, Javadoc, Gradle source-set truth). Rejected: one tool per provider (tool-pick problem).

## Steps

1. **Search seam** (`Example/Umbra/Agent/IDEAgentSymbolSearch.swift`): `IDEAgentSymbol`, `IDEAgentSymbolSearching`, `IDEIndexAgentSymbolSearch` with live-text locating for Java types and members and Swift/TS symbols. Host capability `agentSymbolSearch()` (default `nil`) next to `agentJavaNavigator()`, same gate.
2. **`implementations`** on `IDEAgentNavigating` (default `[]`), implemented by `IDEEngineAgentNavigator` with `NavigationKind.implementation`.
3. **`find_symbol`**: `query`, `limit` (20, max 50); `path:line: kind container.name detail` rows, `(moved since indexing)` and `(outside the project)` markers; an empty result while the index is building says so and points to `grep`.
4. **`explore_symbol`**: `name` (`Calc`, `Calc.add`, `demo.Calc.add`), optional `path` and `line`. Several matches return candidates and never guess. One match: banner if building, header, declaration (doc comment through body, capped), members (types), implementations, usages grouped by file, each capped, pointing to `find_usages` / `read_file` for more. `.read` risk, so plan mode and subagents keep it.
5. **Prompt and cost**: replace the `go_to_definition` rule in `SystemPrompt` instead of adding a line; both tools are added before `go_to_definition` in `IDEAgentConversation.currentSession` so the tool order stays byte-stable.
6. **Tests and docs**: `IDEAgentNavigationTests` (fake search + real `JavaReferenceFixture` integration), tool-definition cost bound, `Example/Umbra/Agent/CLAUDE.md` and `Packages/AgentKit/CLAUDE.md`.

## Validation Plan

- `swift test --filter 'IDEAgentNavigationToolTests|IDEAgentJavaNavigationIntegrationTests|IDEAgentSymbolLocatorTests'`
- `swift test --filter IDEAgentTests/testTheToolsAndSystemPromptStayWithinTheirBudget`
- `swift test --filter IDEAgentEntryPointsTests` — existing ask/fix flows unchanged.
- `cd Packages/AgentKit && swift test`
- Manual: Gradle Java project, "how does a request reach the DB?" — expect `find_symbol` / `explore_symbol` calls and no `read_file` crawl; edit a file without saving and confirm the lines follow the buffer.

## Risks / Open Questions

- Usage search is the expensive part (same cost as `find_usages`); row caps keep the payload small, the tool timeout still applies.
- Ambiguous names (overloads, same simple name): candidates are returned, never a guess.
- Non-goals: callees, library/JDK declarations in search (reachable through `go_to_definition` from a usage), framework route nodes, cross-repo `projectPath`, decompiled bodies inline, paid A/B evals.

## Sources

- [CodeGraph README](https://raw.githubusercontent.com/colbymchenry/codegraph/main/README.md)
- [CodeGraph repository](https://github.com/colbymchenry/codegraph)
