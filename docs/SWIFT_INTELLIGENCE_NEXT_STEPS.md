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
