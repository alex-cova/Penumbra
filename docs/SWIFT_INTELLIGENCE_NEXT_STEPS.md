# Swift intelligence, round two: refactorings and Inspect Code

## Context

`docs/SWIFT_INTELLIGENCE_ROADMAP.md` (Phases 0–6) is implemented and committed on `swift-intelligence`
(`4a542a26`, `ad058530`). Two areas were delivered at a smaller scope than Java has, and the user wants them
continued:

- **Refactorings** (Phase 5): six syntax-only refactorings exist (`Sources/SwiftIntelligence/Refactoring/`).
  Change signature can only add a defaulted parameter or drop the last one; the repository-wide build check was
  skipped; nothing confirms that SourceKit's own refactor actions reach ⌥↩.
- **Inspect Code** (Phase 4): the run, tab, tree and fixes are language-neutral (`IDEInspectionFinding`), but
  Swift has one flat set of options, no profiles or scopes, three places still typed on Java, and 25 rules.

Decision taken with the user: Swift profiles are **stored in the existing profile files with a `swift`
section** (global `InspectionProfiles/<name>.json` and the project's `.umbra/inspections.json`), one picker for
both languages, old files still load.

## A bug to fix first

`JavaInspectionReport.sarif()` / `html()` (`Sources/JavaIntelligence/Inspections/Batch/JavaInspectionReport.swift`)
write the tool name "Umbra Java Inspections" and look every rule up as a `JavaInspectionRule`. Exporting a Swift
run (`IDEWorkspace.inspectionReport(for:root:)`, `Inspections/IDEWorkspace+InspectCode.swift`) therefore labels it
as Java and lists Swift rules with their bare codes. Fix: the report takes a `toolName` and a rule-info lookup
(`(code) -> (title, summary, group)?`), defaulting to today's Java behaviour; Umbra passes
`IDEInspectionLanguage.rule(code:)`. Test: a Swift run's SARIF names "Umbra Swift Inspections" and carries rule
titles.

## Part B: Inspect Code

**B1. Finish the neutral typing (small).**
`Panels/IDEProblemsPanel.swift` (`inspectionRule(for:)`, `IDEProblemRowView.rule/onDisableRule/onQuietRule/onConfigureRule`)
and `Workspace/IDEWorkspace+Inspections.swift` (`performCodeActionCommand`, `showInspectionSettings`) take
`JavaInspectionRule`. Move them to `IDEInspectionRuleInfo` + language so a Swift row gets Disable inspection and
Edit inspection settings, as Java's does. Reuse `IDEWorkspace.disableInspection(code:language:)` and
`showInspectionSettings(code:language:)` (already written).

**B2. ⌥↩ extras for Swift inspections.**
`SwiftCodeActionProvider` (+ `SwiftInspectionService.codeActions`) adds, per finding at the caret:
"Fix all '<rule>' problems in file" (`SwiftBatchFixer.fixAll(rules:in:)`, already exists), "Disable inspection" and
"Edit inspection settings…" as `CodeActionCommand`s (`SwiftInspectionCommand.disable/configure`, argument = rule
code), handled by `performCodeActionCommand` next to `JavaInspectionCommand`. "Turn off highlighting (keep fix)"
comes with B3 (needs the No-highlighting severity).

**B3. Swift profiles (largest item).**
- Library: `SwiftInspectionProfile` (Codable, rules by code so unknown codes survive): `disabled`, `enabled`,
  `severities`, `limits`, ordered `scopedOverrides` (`.tests` or a path glob; first match wins). Model it on
  `JavaInspectionProfile` (`Sources/JavaIntelligence/Inspections/Profiles/`); reuse `SwiftPathGlob`
  (`SwiftIntelligence/Inspections/Batch/`) and `SwiftInspectionScope.isTest`. `profile.options(forFile:projectRoot:)`
  yields the `SwiftInspectionOptions` for one file, which `SwiftInspectionPipeline.analyze` already takes.
- Add `.noHighlighting` to `SwiftInspection.Severity`; the service keeps those findings per file and
  `SwiftCodeActionProvider` still offers their fixes (mirror `JavaInspectionService.quietFindings`).
- Storage: `Inspections/IDEInspectionProfiles.swift` and `IDEWorkspaceInspections.swift` gain a `swift` section
  in the global files and in `.umbra/inspections.json`; `IDEWorkspaceInspections.activeSwiftProfile` follows the
  same project-or-global rule as Java's. On first read, fold the existing `com.umbra.editor.swift*` defaults
  (`IDESwiftInspectionSettings`) into the Default profile. Files without a section load as the standard profile.
- UI: Settings ▸ Swift ▸ Inspections (`Settings/IDESwiftInspectionSettings.swift`) becomes the profile picker and
  menu (reuse the Java pane's profile menu pieces in `IDEPreferencesInspectionsPane.swift`), group toggles, severity,
  limits and per-rule scopes. The Inspect Code sheet (`Inspections/IDEInspectCodeSheet.swift`) shows the profile
  picker for Swift instead of "Uses the inspections switched on in Settings"; `IDEInspectionLaunch.Backend.swift`
  carries the profile and `SwiftBatchInspector.Options` resolves options per file.
- `SwiftInspectionService` reads the active profile (its `OptionsSource` becomes per file).

**B4. More rules (each: positive and quiet tests, a read of the hits over this repository, and every fix must pass
the `SWIFT_INSPECTION_APPLY_FIXES_TO` build check).**
- `unused-local-variable` (from `SwiftSyntaxScopes.references`: a `let`/`var` never referenced, names starting with
  `_` skipped; fix removes the declaration only when the initializer is pure).
- `unused-private-member` (a `private`/`fileprivate` function, property or type whose name appears once in the file;
  annotated and protocol-witness candidates skipped).
- `unused-import`, conservative: only an `import X` where `X` is a target of this package and nothing from `X`'s
  declarations (index) is mentioned in the file; uses `SwiftImportOrganizer`.
- Project-wide `unused-declaration` (internal and private types/functions with no usage, via
  `SwiftReferenceFinder`), off unless "Include project-wide inspections" is ticked, as Java's; add
  `SwiftInspectionRule.isProjectWide` and a "treat public API as used" option (default on).
- Dropped from the first round and still out: `== true`, `fallthrough`, `?? nil` (shown to be unsafe or rare).

**B5. Commit check for Swift.**
`IDEWorkspace.analyzeForCommit` and `reviewCommitAnalysis` (`Inspections/IDEWorkspace+InspectCode.swift`) are
Java-only. Split the staged files by language, count both, and let "Review Problems" open one run tab per language.

**B6. Editor widget.** `IDEInspectionWidget` (file counts at the top right of a Java editor; Settings ▸ Editor ▸
Problem Counts in Java Editors) is Java-only. Show it for Swift files from the Swift inspection diagnostics
(`swift-inspection` source) and rename the setting to cover both.

## Part A: Refactorings

**A1. Full change signature.**
The existing editor flow sends a descriptor's `parameterKeys` to the Java form (`Editor/IDEChangeSignaturePrompt.swift`,
wired in `IDEWorkspace.swift` at `onRequestRefactoringParameters`). Add a Swift form,
`Editor/IDESwiftSignaturePrompt.swift`: a list of parameters (label, name, type, default, call-site value for a new
one; reorder, remove). The descriptor uses `parameterKeys == ["parameters"]` with a JSON-encoded list; the host
chooses the form by that key.
- Library: generalise `SwiftSignatureChange` (`Refactoring/SwiftChangeSignature.swift`) to the new parameter list:
  each entry is an existing parameter (by index) or a new one. Call sites are rebuilt from the old arguments:
  match arguments to old parameters (labels, defaulted parameters left out, variadics, trailing closures), then
  write them in the new order and labels; a call that cannot be matched with certainty is left unchanged and
  listed as a warning (as today).
- Tests: exact-text cases, the cross-file provider tests (`SwiftRefactoringProviderTests`), and new cases in the
  compile gate (`SwiftRefactoringCompileTests`): reorder, relabel, remove an unused parameter, add with a call-site
  value, protocol requirement + conformers.

**A2. Optional-binding shorthand.** `if let x = x` ↔ `if let x` (also `guard let`, `while let`), a code action and a
refactoring id. Offered only when the package's swift-tools-version is 5.7 or later (the manifest model has it).
New `Refactoring/SwiftOptionalBindingShorthand.swift`; cases in the compile gate.

**A3. A Swift menu.** `IDELanguageModule.menu(for:)` returns an `IDEModuleMenu` (Java's is
`Languages/IDEJavaModule.swift`); `IDESwiftModule` has none. Add one with Refactor (the six refactorings + A2),
Inspect Code…, Run Inspection by Name…, Run Tests with Coverage, Profile. The standard editor actions
(`extractVariable`, `inlineVariable`, `changeSignature`) already reach the Swift refactoring provider; confirm the
IntelliJ keys work in a Swift file.

**A4. SourceKit's refactor actions.** Phase 5 relied on SourceKit-LSP for extract method, add `Codable`, convert
to `async`, never checked. Add a case to `Tests/PenumbraTests/SwiftIntelligence/Parity/SwiftSourceKitCeilingTests.swift`
(real `sourcekit-lsp`, skipped without one) that asks for code actions on a selection and lists what comes back;
make sure `LSPCodeActionProvider` maps `refactor.*` kinds and that they appear together with the native ones
without duplicates (the native "Introduce variable" and SourceKit's "Extract variable" may overlap: de-duplicate
by edit or keep SourceKit's). Record the result in the roadmap either way.

**A5. The skipped repository build check.** Run `SWIFT_REFACTOR_APPLY_TO=<copy of Sources>`
(`SwiftRefactoringRepositoryTests.testApplyOneRefactoringPerFileToACopy`), build the copy, fix whatever refuses to
compile, and record the counts. Run it in the background; building the copy takes minutes.

Not planned: extract method and inline method (need types; SourceKit's), safe delete, if→guard for functions that
return a value (the exit statement cannot be known from syntax).

## Order

1. B-bug (report) + B1. 2. A5, A2, A4 (small, independent). 3. B2. 4. B3 (largest; commit alone). 5. B4.
6. A1. 7. B5, B6, A3. 8. Docs and a full-suite run.
Commit after each numbered step. Each step updates `docs/SWIFT_INTELLIGENCE_ROADMAP.md` (status lines) and the
`Umbra/Sources/Umbra/{Swift,Inspections}/CLAUDE.md` it touches.

## Reuse (do not rebuild)

- Profiles: `JavaInspectionProfile`, `IDEInspectionProfiles`, `IDEWorkspaceInspections`, `IDEPreferencesInspectionsPane`.
- Rules/batch: `SwiftInspectionPipeline`, `SwiftBatchInspector`, `SwiftBatchFixer`, `SwiftInspectionQuickFixes`,
  `SwiftPathGlob`, `SwiftInspectionScope`; neutral UI types `IDEInspectionFinding`, `IDEInspectionRuleInfo`.
- Scopes/usages: `SwiftSyntaxScopes`, `SwiftReferenceFinder`, `SwiftRenameProvider` (call sites for change signature).
- Verification oracles: `SwiftParityOracle` (`swiftc -emit-sil`), the `SWIFT_INSPECTION_APPLY_FIXES_TO` and
  `SWIFT_REFACTOR_APPLY_TO` copy-and-build modes.

## Verification

- Per step, only the tests for what changed: `swift test --filter <new test classes>` and the neighbours
  (`SwiftInspection*`, `SwiftBatchInspection*`, `SwiftRefactoring*`; Umbra: `IDESwiftInspect*`, `IDEInspection*`,
  `IDEInspectCodeWorkspaceTests`, `IDEInspectionProfilesTests`, `LanguageCapabilityMatrixTests`).
- Profiles: round-trip tests (old Java-only file loads; file with a `swift` section; migration of the old defaults),
  per-file option resolution with a test scope and a glob scope, the sheet and Settings views in
  `IDEInstrumentationViewsSmokeTests`-style smoke tests.
- Rules: every new rule gets the 0-false-positive review over `Sources/` and the apply-fixes build check
  (`count-is-zero` showed why).
- Refactorings: every new case in `SwiftRefactoringCompileTests` (swiftc before and after).
- At the end only: `caffeinate -u -d -i -s swift test` and `… --package-path Umbra` once, in the background.
  The Umbra suite already has pre-existing, environment-dependent failures (two Ghostty tests; two load-sensitive
  tests that pass alone); anything else is mine.
- Manual (`./run.sh`): Inspect Code on a Swift folder with a profile that scopes `Tests`; ⌥↩ extras on a finding; change
  signature form on a function with callers in two files; Swift ▸ Refactor menu.

## Progress

- **Step 1 (done).** `JavaInspectionReport` takes a tool name and its own rule table (`RuleInfo`), so a Swift run exports as "Umbra Swift Inspections" with Swift rule titles (Java's default is unchanged). The Problems row menu (`IDEProblemsPanel`) is typed on `IDEInspectionRuleInfo`: a Swift inspection row gets Disable Inspection and Edit Inspection Settings (Turn Off Highlighting stays Java-only until B3). Tests: `IDESwiftInspectCodeTests` (SARIF/HTML of a Swift run).
- **Step 2 (done).** **A5**, the repository build check, found two real bugs, both fixed and covered by tests: moving a struct's only explicit `init` to an extension brought the synthesized memberwise `init` back and clashed with it (`HexKit`); `guard` → `if` was offered inside a nested block, where the `return`/`continue` it removed also skipped the code after the enclosing statement (`JavaStaticImports`), and for `break`, which is never equivalent. It is now offered only when the guard's block is the function, closure or loop body itself. After the fixes one refactoring was applied to each of 860 files of `Sources/` (272 if→guard, 17 inline, 568 move, 3 shorthand) and the copy builds (`SwiftRefactoringRepositoryTests.testApplyOneRefactoringPerFileToACopy`, `SWIFT_REFACTOR_APPLY_TO`). `SwiftRefactoringFile.references` is cached per file, which made the run take 30 s instead of minutes. **A2**: `SwiftOptionalBindingShorthand` (`if let x = x` ↔ `if let x`, also `guard`/`while`/`var`/`self`), offered as a refactoring and at ⌥↩; shortening only when the nearest `Package.swift` declares swift-tools-version 5.7 or later (`SwiftToolsVersion`). **A4**: SourceKit-LSP's refactorings (Extract Expression, Extract Method, Extract Repeated Expression for a selection; Add documentation at a caret) never reached the editor, for two reasons: the client always sent an empty range to `textDocument/codeAction`, and the server offers them as commands (`semantic.refactor.command`) whose edit comes back in a `workspace/applyEdit` request, which the client dropped. `LanguageServerClient` now sends the selection when it holds the caret, advertises `workspace.applyEdit`, and resolves each `refactor.*` command action by running the command and keeping the edit it sends back (at most eight per request, only when it edits this document), so choosing one is an ordinary edit. Tests: `LSPFakeServerTests` (a fake server that waits for the client's `applyEdit` answer, as the real one does), `SwiftSourceKitCeilingTests.testSourceKitOffersRefactoringsForASelection` (real `sourcekit-lsp`, `SWIFT_PARITY=1`). The native "Introduce variable" and SourceKit's "Extract Expression" can both appear; both are kept (the native one refuses unsafe cases and works while the server is starting).
- **Step 3 (done, B2).** A Swift inspection at the caret now offers, once per rule, "Fix all '<rule>' problems in file" (when the file has more than one finding and the fixes do not collide: `SwiftBatchFixer.fixAll`), "Disable inspection '<rule>'" and "Edit inspection settings…" (`SwiftInspectionCommand.disable/configure`, handled by `IDEWorkspace.performCodeActionCommand` next to Java's). "Turn off highlighting (keep fix)" waits for B3. Tests: `SwiftInspectionTests.testTheMenuOffersFixAll…`, `IDESwiftInspectCodeTests.testTheMenusCommands…`.
- **Step 4 (done, B3).** Swift profiles. `SwiftInspectionProfile` (deviations, severities, limits, ordered scopes for tests or a path glob, first match wins; `options(for:)` resolves a file) is kept in the `swift` section of the existing profile files: `JavaInspectionProfile.sections` passes any other language's JSON through untouched, so global profile files, the project's `.umbra/inspections.json`, Duplicate/Rename/Delete/Export all carry it and old files load as the standard Swift profile. Default keeps its section in `com.umbra.editor.swiftInspectionProfile`, seeded once from the four flat keys Settings ▸ Swift used. `SwiftInspection.Severity` gained `noHighlighting`: nothing drawn or listed in the editor, the fix stays on ⌥↩ ("Turn off highlighting for '<rule>' (keep fix)" is offered), Inspect Code still lists it. The editor's `SwiftInspectionService` takes options per file (`init(optionsForFile:)`) from `IDESwiftInspectionResolver`, the batch run through `SwiftBatchInspector.Options.optionsForFile`, so a `Tests` scope switches a rule off for test files in both. Settings ▸ Swift ▸ Inspections is the profile picker and menu, filter, group toggles, severity, thresholds and a scopes editor per rule; the Inspect Code sheet shows the same profile picker for Swift. Tests: `SwiftInspectionProfileTests`, `JavaInspectionProfileTests` (section pass-through), `IDESwiftInspectionSettingsTests`, `IDESwiftInspectCodeTests`, `IDESwiftInspectionViewsSmokeTests`.
- **Step 5 (done, B4, narrower than planned).** Two rules, in a new "Unused code" group; two of the planned four were dropped on purpose. **`unused-local-variable` is not added:** `swiftc` already warns about an unused value, so the native rule would double SourceKit's squiggle. **`unused-import` is not added:** deciding that nothing from a module is used needs that module's declared names, which the index only has for this project's own targets; it stays open. **`unused-private-member`** (on by default, file-level): a `private`/`fileprivate` function, property or type whose name is written nowhere else in the file. It leaves alone anything with an attribute, `override`/`dynamic`, `private(set)`, protocol members, names a framework or the compiler calls (`body`, `CodingKeys`, `makeUIView`…) and members of types whose attributes could reach them from a macro (`@Observable`, `@Model`…). Over this repository's `Sources`, `Umbra/Sources` and `Packages` it reported 19 declarations, all verified unused (each name occurs once in the whole project). **`unused-declaration`** (project-wide, run by Inspect Code behind "Include project-wide inspections", never as you type): an internal type, function or property whose name no other file writes (`SwiftProjectNameLookup`, answered by `SwiftIndex.candidateFiles`; `SwiftInspectionPipeline.analyze(text:options:url:isTest:lookup:)` is the async path). By name, not by resolved use, so it can miss an unused declaration whose name something else shares; it never reports one because of a collision. It also skips public/open API (the profile's "treat public API as used", default on), attributed declarations, overrides, protocol requirements, every member of a type or extension that lists a protocol or superclass (a delegate callback, an associated-type alias or a synthesized `Codable` key is used without being written), padding fields, names of one or two characters, tests and `main.swift`. The first review of the repository found 93 hits, among them those false positives (a delegate callback, `typealias Magnitude`, `Codable` fields, a `pad4` field); with them excluded 57 remain, all checked by hand. Inspect Code waits for the index (`IDESwiftSupport.waitForIndex()`) before a project-wide run. Tests: `SwiftInspectionTests` (private), `SwiftProjectInspectionTests`, `IDESwiftInspectCodeTests.testProjectWideInspectionsAskTheIndex…`. No fixes (deleting code is the user's call).
- **Step 6 (done, A1).** Full change signature. `SwiftChangeSignature` now takes the whole parameter list the function should have (`SwiftSignatureParameter`: old place or new, label, name, type, default, the value existing calls pass): reorder, relabel, rename the internal name (renamed through the body of the declaration asked about; an override or conformer keeps its own internal names), add (a default, or a value every call passes), remove (refused when the body reads it). Declarations of the whole family (overrides, protocol requirements, conformers) are rewritten; a call is rewritten when its arguments match the old parameters with certainty (labels, defaulted parameters left out, variadics, trailing closures that stay last, labels of additional trailing closures), otherwise it is left and listed as a warning. A list spread over lines stays spread over lines. The editor's form is `IDESwiftSignaturePrompt` (a popover under the caret: label, name, type, default and "Calls get" per row, move up/down, remove, add, a preview of the declaration and the reason a list cannot be applied), chosen by `descriptor.parameterKeys == ["parameters"]`; Java's add-or-remove form is untouched. Tests: 14 engine cases in `SwiftRefactoringTests`, the cross-file cases of `SwiftRefactoringProviderTests`, 10 more cases in the `swiftc` gate (`SwiftRefactoringCompileTests`: reorder, relabel, add with a call-site value, add with a default, remove, rename, protocol + conformer, trailing closure, variadic, multi-line), `IDESwiftSignatureModelTests` (Umbra).

