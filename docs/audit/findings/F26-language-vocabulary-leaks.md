# F26 — Closed-enum vocabulary and Java defaults leak

- **Priority:** P3 (before the first function-centric language) · **Severity:** Medium · **Confidence:** Confirmed · **Provenance:** A+B
- **Status:** ✅ Done (2026-11-04) — vocabulary, LSP outline, per-language inline validators and the Java default; the `"java"` checks in `IDEWorkspace` are not leaks · **Owner:** Unassigned

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

## Implementation notes (2026-11-04)

**Audit first, as the brief asked (the compiler did the switch audit).** Of the five enums the brief names, only two lacked what a function-centric language needs: `CompletionItemKind` already has `function`, `module`, `package`; `DiagnosticSourceID` is an open `RawRepresentable`; `LineMarkerKind` and `NavigationKind` are Java-flavoured in their doc comments but need no new case for Python/Rust/Go. Adding cases to `StructureKind` and `HierarchyItemKind` made exactly four exhaustive switches fail, in two Umbra files (`IDEBreadcrumbMenu`, `IDETypeHierarchyPanel`); the diagram, palette and agent switches are over other enums (`JavaMemberKind`, the diagram's own kinds).

**Done.**
- `StructureKind` += `function`, `module`, `variable`; `HierarchyItemKind` += `structType`, `traitType`, `function` (additive; icons and names in the breadcrumb menu and hierarchy panel).
- **A language server could not outline a file at all.** `LSPLanguageService` built no `StructureProviding`, and `LSPOutlineSymbol` carried the kind as `String(describing:)`. Now `LSPClient.requestDocumentSymbolTree` (a neutral `LSPDocumentSymbol` with the numeric `SymbolKind`, the full range and the name range; default `[]`), `LanguageServerClient` implements it, and `LSPReadyStructure` (`EditorIntelligenceLSP/LSPStructure.swift`) maps it: class/enum/interface/struct → `type`, method → `method`, a top-level function → `function`, variable/constant → `variable`, module/namespace/package → `module`; positions become UTF-16 offsets (CRLF, `\r`, multibyte text). A file with no type is outlined as a `module` of its symbols instead of "No type at the caret". Opt in with `.structure` in the configuration's `enabledFeatures` (not in the defaults: Swift and TypeScript have native outlines).
- `StructureProviding` gets `structure(forSource:document:atUTF16Offset:)` / `allStructure(forSource:document:)` with defaults that ignore the document, so no existing provider changed; a provider that asks a server needs the document's identity. Umbra's three callers (structure sidebar, File Structure, breadcrumb menu) pass `adapter.currentDocument`.
- The LSP hierarchy mapping (`hierarchyKind`) was lossy: a function became `method` and a struct `class`. Now function → `function`, struct → `structType`.
- **Inline completion.** `InlineCompletionEngine` takes `validators: [String: …]` by language (the single `validator` stays as the fallback); Umbra registers `["java": javaSupport.completionProvider]`, so the Java validator no longer sits in front of every language. `InlineCompletionSettings.languageIDs` defaults to empty; Umbra sets it from `IDEIntelligenceServices.inlineValidatedLanguages`.
- Tests (`FunctionCentricLanguageTests`, 8): the function-centric fixture outlines with the right kinds and name ranges after CRLFs and multibyte text; innermost type else module root; no outline without a document, a connection or the right language; the document entry point falls back for a text-only provider; the kind tables; per-language validators; no default validation-grade language. Library 551 and Umbra 144 related tests pass.

**Not a leak.** The brief counted "~8 generic `languageIdentifier == "java"` checks in IDEWorkspace". The six that exist sit in Java-only features (`openJavaDocumentIDs`, `openJavaDocuments`, `scheduleJavaAutoImport`, the Java name-index overlay and its close hook), so none was changed.

**Left on purpose.** `RenameTarget.validatePackageName` is a general package-name rule (Go and Python have packages too; Java's Move Class and the move-package prompt use it) and `Location.Target.package`'s doc example names `java.util`: cosmetic, no behaviour. `LineMarkerKind`/`NavigationKind` doc comments stay Java-flavoured.

**Not done.** No Python/Rust/Go server is configured (this finding was vocabulary and plumbing): turning one on is an `LSPLanguageConfiguration` with `.structure` (and `.typeHierarchy`/`.callHierarchy`) plus a host server definition. The outline is as fresh as the adapter's document (≤200 ms behind the live text, like the other LSP features).
