# F26 — Closed-enum vocabulary and Java defaults leak

- **Priority:** P3 (before the first function-centric language) · **Severity:** Medium · **Confidence:** Confirmed · **Provenance:** A+B
- **Status:** Open · **Owner:** Unassigned

## Evidence

- Closed enums in generic EditorIntelligence types lack function/module concepts: `StructureKind` (type/field/method/constructor/enumConstant/recordComponent) and `HierarchyItemKind` (class/interface/enum/record/annotation/method) at Sources/EditorIntelligence/Languages/LanguageFeatures.swift:79-153; also `LineMarkerKind`, `CompletionItemKind`, `NavigationKind`. `LanguageFeatures.swift:3` admits the file "had no generic protocol while Java was the only language". Python top-level functions, Rust traits, and Go structs map lossily.
- Minor Java leaks in generic code: `DiagnosticSourceID.javac` (RawRepresentable-extensible, low risk), `RenameProviding.validatePackageName`, `Target.package` doc example.
- Defaults past the boundary: `InlineCompletionSettings.languageIDs = ["java"]` (Sources/Penumbra/EditorIntelligenceAdapter/InlineCompletionController.swift:20-24); Umbra hardwires the Java provider as inline-completion validator for all languages (IDEIntelligenceServices.swift:162-166); ~8 generic `languageIdentifier == "java"` checks in IDEWorkspace.
- Control flow is clean: registry/routing/engines are identifier-keyed with no Java branching; Swift + TypeScript ship natively and via the generic LSP service. This finding is vocabulary only.

## Root cause

Java was the first semantic language, so its nouns became the generic nouns.

## Fix sketch

When the first function-centric language lands: add `function`/`module` cases additively (audit exhaustive switches client-by-client first — unaudited today), default `languageIDs` to host-supplied, and route inline-completion validation through the registry.

## Complexity / Dependencies

S per item; the switch audit is the real work. Blocks native Python/Rust/Go; does not block Python-via-LSP.

## Acceptance criteria

- A function-centric language's symbols render with correct kinds in structure view/hierarchy; no Java-named default applies to non-Java files.

## Tests / benchmarks

- LanguageServiceConformance tests with a function-centric fixture language.

## Out of scope

EditorIntelligence redesign — the current registry shape is the smallest viable form; keep it.
