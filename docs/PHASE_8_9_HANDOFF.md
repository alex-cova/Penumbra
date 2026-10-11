# Handoff: phase 8 and phase 9

## Spike result (Oct 10 2026)

Phase 8's `SourceFileIndex<Model>` is in `Sources/EditorIntelligence/Indexing/SourceFileIndex.swift`. Phase 9 did not add `IDEDebugSession`.

`lldb-dap` is `/Applications/Xcode.app/Contents/Developer/usr/bin/lldb-dap` (LLVM 21.0.0, liblldb 2103.0.34.103). Through SubprocessKit, `initialize` succeeds and no `initialized` event follows. `launch` (with the breakpoint and `configurationDone` already queued) never returns a message, and `lldb` `run` hangs in debugserver the same way. The detail is in `docs/LANGUAGE_PARITY_PLAN.md` under "lldb-dap spike".

Read `docs/LANGUAGE_PARITY_PLAN.md` (the status block, then phases 8 and 9) and `docs/LANGUAGE_PARITY_HANDOFF.md`. Phases 0–7 are done. Do not redo them. Phase 10 stays gated. Do not start phase 9's types before the lldb-dap spike below has a written result.

Decisions already made: TypeScript's semantic tier is LSP. External servers are first-class. The App Sandbox spike stays in phase 10. Do not grow the native Swift or TypeScript engines into type checkers. Do not wrap `JavaDebugSession` until a Swift DAP session has stopped on a breakpoint.

## Phase 8 — `SourceFileIndex<Model>`

Optional maintenance. Do it as a pure extraction. `SwiftIndex` and `TypeScriptIndex` each own the same walk:

- Enumerate from the project root with `FileManager`, `.skipsHiddenFiles`, directory skip, source-file check, 1 MB cap (`SwiftPaths.maxBytes` / `TypeScriptPaths.maxBytes`, both `1_048_576`).
- Parse with a fan-out of 8 (`parseAll` in both files). A cancelled task publishes nothing.
- `generation` plus `buildingToken`. A newer `setRoot` wins. A cancelled walk returns without replacing the tables.
- `pendingEdits` records adds and deletes that arrive while a walk is in flight, and those edits are merged before the walk publishes.
- Open-buffer lookup: `(@Sendable (URL) async -> String?)?`. `source(for:)` tries the standardized URL, then the original URL, then disk when the file is indexed.

Put the shared actor in `EditorIntelligence`. Both `SwiftIntelligence` and `TypeScriptIntelligence` already depend on it, and it has no dependencies of its own. Do not add a target. Do not put it in `LanguageSyntax` (that module is the parser). Do not move Java's index. Java's shards and Gradle model are a different design.

Skip lists and extensions stay on `SwiftPaths` and `TypeScriptPaths`. The kit takes them as configuration. Swift skips `.build`, `.swiftpm`, `DerivedData`, `Pods`, `Carthage`, `checkouts`, `node_modules`, `.git`, `xcuserdata`, and `Package.swift` / `Package@swift-*.swift` (`SwiftPaths.isManifest`). TypeScript skips `node_modules`, `dist`, `build`, `coverage`, `.git`, `.next`, `out`.

### Keep these differences

The public methods of `SwiftIndex` and `TypeScriptIndex` stay. Callers and tests must not change.

- Swift `applyFileChanges` is synchronous and updates its lookup tables immediately (`remove` / `add`). TypeScript's is `async`, writes the file map immediately, and calls `publish` only when no walk is in flight.
- Swift `noteOpenDocument` parses, stores `bufferHashes`, and skips a repeat of the same text. TypeScript has no such method. `TypeScriptIndex.model(for:)` reparses `source(for:)` on every call. `SwiftIndex.model(for:)` refreshes from the open buffer and returns the stored model.
- Swift's cold parse is `SwiftAnalysis.parseModel` (no tree kept). TypeScript's is `TypeScriptAnalysis.parse(_:fileURL:)`, and the URL chooses the TSX grammar for `.tsx` / `.jsx`.
- Lookup tables stay in each index: Swift's types, extensions, modules, and `setModuleResolver`; TypeScript's exports, re-exports, `resolve(specifier:from:)`, and palette symbols. The kit stores files and tells the index when a file was added or removed. It does not know about declarations.

### Accept

`SwiftIndexTests` and the TypeScript index tests pass unchanged. `swift-index` and `ts-index` stay within the noise of the numbers in `docs/EDITOR_PERF_PLAN.md` (one run is not a gate: Swift cold `setRoot` 42 ms / +9.9 MB, TypeScript 44 ms / +7.6 MB, 1000 files).

## Phase 9 — debugger, spike first

Gated. The order is fixed.

### 1. Spike, and stop

Prove `lldb-dap` against a tiny Swift program before any new debugger type exists. The spike is a gated test or a small Umbra-side tool, skipped when the binary is absent (same idea as `UMBRA_SOURCEKIT_LSP=1`). Discovery: a user path, then `xcrun --find lldb-dap`. Launch through `SubprocessKit`. `JavaDebugProcessLauncher` uses `Foundation.Process`; new process code does not.

The session has to: `initialize`, launch the program, set one breakpoint, `continue`, receive `stopped`, read a stack frame, read one variable, `step`, and evaluate one expression.

Write the result down (a short section in `docs/LANGUAGE_PARITY_PLAN.md` or a note next to this file): which `lldb-dap`, what succeeded, and what failed. If launch, the stop, or variables fail, stop. Do not add `IDEDebugSession`.

### 2. Abstraction, only after the spike

`IDEDebugSession`: breakpoints, threads, frames, variables, evaluate, step. `DAPDebugSession` speaks DAP for `lldb-dap`. Wire that to the existing Debug tool window for a Swift target.

Then a thin wrapper so `JavaDebugSession` conforms. The Debug panel today is built on `JavaDebugStackFrame`, `JavaDebugThread`, `JavaDebugValue`, and `JavaDebugSessionState` (`Example/Umbra/JavaDebugSession.swift`, `IDEWorkspace+Debugger.swift`). Shape the protocol from what the Swift session actually did, then adapt Java to it. Java's debugger tests stay unchanged.

js-debug is plan item T7, after this phase. It is not part of the spike and not part of the first `DAPDebugSession` landing.

### Accept

The gated tests pass: breakpoint, step, variables. `JavaDebugSession` tests pass unchanged.

## Out of scope

- Phase 10: a Go or Rust module that is only an `IDELanguageServerDefinition`, and the sandbox spike.
- A type checker in `SwiftIntelligence` or `TypeScriptIntelligence`.
- Xcode projects and SwiftUI previews.
- Wrapping `JavaDebugSession` before the spike.

## Traps

- `*Intelligence` must not depend on `Penumbra` or `SubprocessKit`. Only Umbra spawns processes. The index kit can live in `EditorIntelligence`. The DAP process cannot.
- In `EditorIntelligence`, a protocol method with a default is not dispatched on the existential. `tier`, `unavailableFeatures`, `cancellableRequest`, and `LSPConnectionBox.supportedFeatures` are properties and do dispatch.
- Do not name a new type `SyntaxTree` in a module that imports `EditorIntelligence`. `LanguageSyntax.SyntaxTree` is the concrete tree.
- Swift fixtures under `Tests/PenumbraTests/` are compiled unless excluded in `Package.swift`.
- The TypeScript completion baseline is the native `box.` completion on a 5000-line file: median 4.94 s, reparse 1.8 ms (`docs/EDITOR_PERF_PLAN.md`). Do not hide it.
- `caffeinate -u -d -i -s swift test` for the full suite. The display must stay on. One `enter-session` run is not a gate.

## Checks

```bash
swift test --filter 'SwiftIndexTests|TypeScriptIntelligenceTests'
```

After the spike exists, the gated lldb-dap test, then the Java debugger tests on their own. The full suite has not been run for phases 0–7.
