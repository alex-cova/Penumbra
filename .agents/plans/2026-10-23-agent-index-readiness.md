## Goal

Make `find_symbol` / `explore_symbol` say, accurately, when an index they depend on is not ready, for Java, Swift and TypeScript alike. Follow-up to `2026-10-23-agent-code-index.md`.

## What is wrong today

The "index is still being built" banner and the empty-result guidance read `IDEProjectStatus.message` (`IDEWorkspace+Agent.swift`, `agentSymbolSearch()`). That string is a progress toast shared by every project system, not an index signal:

1. **Swift and TypeScript never set it.** `IDESwiftSupport` / `IDETypeScriptSupport` run `index.setRoot(root)` in a bare `Task`. While the walk runs the index is empty (or still holds the previous project), so `find_symbol` answers "No project declaration matches" with no warning.
2. **False positives.** Gradle ("Resolving…"), SwiftPM, Xcode, npm (`setStatus`) and Maven (`handleReadError` sets an *error summary*) write the same field. The model is told "the index is still being built (Maven failed: …)".
3. **Java usages are not covered.** `explore_symbol` finds usages and implementations through `JavaNameIndex` (`buildNameIndex` / `updateNameIndex`), which builds separately and sets no status. Until it finishes, "Usages: none found" looks like a fact.
4. **A gap at the start.** `projectDidChange` launches a `Task`; until the actor's `setRoot` runs, `SourceFileIndex.isBuilding` is still false and `fileCount` is 0, so "not started" looks like "empty project".
5. **Java's own message is conditional.** `indexWholeTree` only sets "Indexing project sources…" when `status.message == nil`, and Gradle sync replaces and clears it, so the signal can disappear while indexing continues.

## Approach

Stop parsing a toast. Add one small explicit source of truth, `IDEIndexActivity`, that the three language supports update and the agent reads. The toast and the banner stay independent.

```swift
@MainActor final class IDEIndexActivity {
    enum Kind: Hashable { case javaSources, javaDependencies, javaUsages, swift, typeScript }
    func begin(_ kind: Kind) -> Token      // counts, so overlapping builds of one kind stay active
    func end(_ token: Token)               // idempotent
    var active: Set<Kind>                  // what is building right now
}
```

- Owned by `IDEIntelligenceServices` next to `projectStatus`, handed to `IDEJavaSupport`, `IDESwiftSupport`, `IDETypeScriptSupport`.
- `begin` is called **synchronously on the main actor in `projectDidChange`** (closes gap 4), `end` in a `defer` inside the build `Task`. A task cancelled by a newer `projectDidChange` still runs its body and its `defer`, and the newer call's token keeps the kind active, so a superseded build never reports ready early.
- Java: `.javaSources` around `indexWholeTree`'s scheduler loop, `.javaDependencies` around the dependency block in `applyGradleModel` (where "Indexing dependencies…" is set today), `.javaUsages` around `nameIndexTask` in `buildNameIndex` / `updateNameIndex`. The toast messages stay exactly as they are.
- Swift / TypeScript: `.swift` / `.typeScript` around `rebuild`. Also expose `public var isBuilding: Bool { storage.isBuilding }` on `SwiftIndex` and `TypeScriptIndex` (the data already exists in `SourceFileIndex`) so a build started outside the support class is still seen.

### Agent side

Replace `IDEAgentSymbolSearching.indexStatus() -> String?` with `indexReadiness() async -> IDEAgentIndexReadiness`, a pure value:

```swift
struct IDEAgentIndexReadiness: Sendable, Equatable {
    var pending: [Part]            // .javaSources, .javaDependencies, .javaUsages, .swift, .typeScript
    var isReady: Bool { pending.isEmpty }
    var description: String        // "Java project sources, Java usages"
}
```

Wording changes in `IDEFindSymbolTool` / `IDEExploreSymbolTool`:

- Banner (unchanged shape): `[Still indexing: Java usages. Results for those may be incomplete; grep covers what the index has not reached.]`, listing exactly the pending parts.
- Empty `find_symbol` / unknown `explore_symbol` name: "Nothing found yet" only when a *symbol-bearing* part for that language is pending (`javaSources`, `swift`, `typeScript`); otherwise the normal "No project declaration…" text.
- `explore_symbol` usages and implementations: when `.javaUsages` is pending for a Java symbol (or `.swift` / `.typeScript` for theirs), print `Usages: not available yet (the usage index is still building). Use grep, or ask again shortly.` instead of `Usages: none found`. An empty result with the index ready keeps today's text.

## Steps

1. `IDEIndexActivity` (+ `Kind`, `Token`) in `Example/Umbra/`, created in `IDEIntelligenceServices`.
2. `SwiftIndex.isBuilding`, `TypeScriptIndex.isBuilding` (one line each, public).
3. Wire Swift and TypeScript supports: `begin` in `projectDidChange`, `end` in the task's `defer`; expose `isIndexing`.
4. Wire Java: the three places above. Do not touch the toast logic.
5. `IDEAgentIndexReadiness`; swap the protocol member, `IDEIndexAgentSymbolSearch`, `IDEWorkspace.agentSymbolSearch()`, both tools, and `FakeSearch` / `NoSearch` in the tests.
6. Docs: `Example/Umbra/Agent/CLAUDE.md` (the name-search paragraph says the banner reads the shared status; fix it), `Example/Umbra/Swift/CLAUDE.md` and the TypeScript notes if they describe indexing.

## Tests

- `IDEIndexActivityTests`: begin/end, two tokens of one kind keep it active until both end, double `end` is safe, kinds are independent.
- Support layer, deterministic: `IDESwiftSupport.projectDidChange(root:)` makes `isIndexing` true before returning; true again for a second call that cancels the first; false only after the last build ends (poll with the existing `eventually` helper). Same for TypeScript.
- `SwiftIndex` / `TypeScriptIndex`: `isBuilding` is false before and after `setRoot` on a small temp tree.
- Tool tests with a fake readiness: banner lists exactly the pending parts; an unrelated pending part (e.g. TypeScript while the answer is a Java symbol) does not turn an empty Java result into "Nothing found yet"; `Usages: not available yet` appears only with the matching usage part pending and not when it is ready; "none found" is unchanged when ready.
- Regression for false positives: a window whose `projectStatus.message` is "npm install…" with no index activity produces no banner.
- Existing suites stay green: `IDEAgentSymbolToolTests`, `IDEAgentSymbolIntegrationTests`, `IDEAgentControllerTests.testNameSearchLeads…`, and `swift test --filter 'Swift|TypeScript'` index suites.

## Verification

```bash
swift build --product Umbra
caffeinate -u -d -i -s swift test --filter 'IDEIndexActivityTests|IDEAgentSymbol|IDEAgentControllerTests|SwiftIndex|TypeScriptIndex'
```

Manual in `swift run Umbra`: open a large Swift or TypeScript folder, send `find_symbol` immediately; expect the "Still indexing: Swift" banner or "Nothing found yet", then real rows once the walk finishes. Open a Gradle project and call `explore_symbol` on a class right after opening; expect "Usages: not available yet" until the name index is built.

## Risks / Open Questions

- **Missed `end`**: a code path that begins and never ends leaves a permanent banner. Mitigation: `begin` and `defer { end }` are always paired in the same scope, and a test cancels a build mid-way.
- **Java dependencies are not needed for project-source search**, so `.javaDependencies` only changes the banner, not the empty-result wording.
- **Open question**: should a Gradle sync in progress (`syncState.isSyncing`) count as pending? It affects source-set scoping of implementations and usages, but not name search. Left out of v1; add as a `.projectSync` part if real runs show wrong scoping during a sync.
- **Non-goals**: showing readiness in the chat UI, waiting for the index before answering (a tool call never blocks on indexing), changing the toast.
