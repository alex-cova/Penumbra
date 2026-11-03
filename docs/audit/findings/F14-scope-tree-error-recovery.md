# F14 — JavaScopeTree unwired; ERROR-node local loss

- **Priority:** P2 · **Severity:** High · **Confidence:** Confirmed · **Provenance:** A+B
- **Status:** Implemented (see Implementation notes) · **Owner:** Unassigned

## Evidence

- `JavaScopeTree` (Sources/JavaIntelligence/Semantics, ~982-line memoized successor) has zero callers in `Completion/` (grep). Live completion runs per-query `JavaLocalScope` ancestor walks, `O(depth × siblings)` per query.
- `JavaLocalScope:59-68` documents ERROR-node collapse: locals in a malformed method are unrecoverable; only parameters survive.
- Error recovery elsewhere is a heuristic stack (dummy identifier, `;`/paren repair, receiver text scanner, synthetic re-parse) with silent-nil exits that present as "no suggestions", indistinguishable from a legitimately empty result.

## Root cause

The scope model was rebuilt but never wired into the provider path; recovery heuristics accumulated instead.

## Fix sketch

Wire `JavaScopeTree` into `JavaCompletionProvider`; add error-recovery attribution so declarations before the ERROR region still resolve; log/meter silent-nil exits distinctly from empty results.

## Complexity / Dependencies

M. Prerequisite for F01 full effect.

## Acceptance criteria

- Malformed-file fixture: locals declared before the error complete correctly.
- Scope-tree path used in provider (grep + test); no completion regressions on corpus.

## Tests / benchmarks

- Malformed-file completion tests; Java corpus; scope-tree ~6 ms/2k-line figure re-verified end-to-end (it is scope-only today).

## Out of scope

Full attributor (F01).

## Implementation notes

2026-11-03. The brief's evidence was partly stale: member completion already read the scope tree through `visibleLocals` (added in F01), so the work was the remaining callers, the tree's own gaps and ERROR recovery.

- **Wired.** Every `JavaLocalScope.locals` call in `Completion/` (statement items, expected types, takenNames, postfix, signature help, inline-completion validation) now goes through `JavaSyntaxTree.visibleLocals`: scope-tree locals for the outermost method/constructor around the offset, then any name only the old scan finds (so it is a strict superset of either source). The per-member build is memoized per parse (`JavaExecutableScopeCache`). Not wired: non-completion users (usage resolution, inlay hints, go to type definition, intentions, extract method) still call `JavaLocalScope` directly.
- **Tree gap fixed.** `expressionScopes` built scopes only for lambdas and anonymous bodies, so a `switch` used as a value (initializer, argument, `return`) had no rule scopes and its pattern bindings were invisible, with or without an ERROR. It now builds the switch block. Unit tests in `JavaScopeTreeTests` fail without the change.
- **ERROR recovery.** The old claim that locals in a collapsed method are "genuinely unrecoverable" was wrong: a method that collapses into one flat `ERROR` keeps its `local_variable_declaration`s as direct children in source order. `JavaLocalScope` now recovers them (`collectFlatLocals`, brace-aware). A balanced `{ … }` stays a `block` child that is never entered, so its locals do not leak; only unmatched braces are tracked, and no fixture reaches that branch.
- **Completion rule.** The tree puts a local in scope inside its own initializer (JLS 6.3, pinned by its tests); completion must not offer it, so `visibleLocals` drops the variable whose declarator holds the caret. Without this six ratcheted corpus cases regressed.
- **Silent exits.** A receiver that does not type now logs the receiver text (private) on both the `.` and `::` paths. This is a debug log, not a metric; there is no counter.
- **Corpus.** 14 `Err*` cases (broken statement before the caret, unclosed call, missing brace, next method broken, broken `for` header, constructor, `try`, `yield`, closed/open blocks) plus the former `yield` gap; 296 cases, 296 pass, 0 gaps. Release `java-completion synthetic` large-file member access 10.9–11.2 ms vs 11.0–11.3 ms parent; `statement_expected` +9 µs (0.196 → 0.205 ms).
- **Was found and left open; see the second pass.** `if (a.\n a.` is genuinely `a.a.` in Java and is not a bug.

### Second pass (same day): the other scope implementations and the unbalanced call

The first pass wired completion. Probing the rest showed the scope model exists four times, and the three that completion does not use each missed binding forms the scope tree knows.

- **`JavaSemanticWalker`** (Find Usages of a local, Rename, semantic highlighting). It bound `case T t` patterns only. A variable introduced by `o instanceof String s` or by a record pattern component (`Point(int x, int y)`) had no declaration at all, so Find Usages returned nothing, Rename had nothing to rename, and the variable was not highlighted as a local. Now `instanceof_expression` and `record_pattern_component` bind a local (flow scoping such as `if (!(o instanceof String s)) return; s.length();` works because the binding lands in the enclosing scope). `JavaPatternBindingUsagesTests`: 9 cases, all fail without the change.
- **`JavaReferenceClassifier` / `JavaSymbolIdentity`** (caret to symbol). Neither recognised a pattern binding as a declaration, so `prepareRename` returned nil on one. Both do now.
- **`JavaDeclarationLocator.localDeclarationRange`** (a use to its declaration). Its own ancestor walk listed blocks, parameters, lambdas, enhanced-for, resources, and missed pattern bindings, `catch` parameters and classic `for` variables, so Rename from a use of any of those fell through to field lookup and could bind an unrelated field of the same name. It now asks the scope tree first (`JavaScopeTree.localDeclarationRange`, executable-scoped and memoized like `locals(in:enclosingExecutableAtByteOffset:)`) and keeps the old walk for `ERROR` regions. `JavaRenameProviderTests.testRenameFromAUseOfPatternForAndCatchVariables` (fails for the pattern and the `for` variable without it) and `testInstanceofAndRecordPatternBindingsRename`.
- **Unbalanced call before the caret.** `println(x.length(;` followed by a statement left the parentheses open, so statement completion on the next line returned nothing. `JavaCompletionProvider.blankingBrokenStatements` replaces the unmatched `(` of an earlier line that ends in `;` with `+` (a one-character replacement, because the request maps original-document offsets onto the repaired text; a space instead creates a bogus declaration `System.out.println itemKept` that shadows the real local, which is why `+`). `for (` headers, balanced and multi-line calls, strings and `//` comments are left alone; only the 40 lines above the caret are read. Corpus `ErrUnbalanced*`, `ErrControl*`; `JavaBrokenStatementRepairTests`.
- **Still open.** `JavaLocalScope` is still the source for receiver typing in usage resolution, inlay hints, go to type definition, the type intention and the extract refactorings (none of them see pattern bindings or a switch used as a value when they type a receiver); Go to Type Definition on a pattern binding itself returns nothing; the scope tree still loses locals inside `ERROR` regions and relies on `JavaLocalScope` for them.
