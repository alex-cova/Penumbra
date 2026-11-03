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
- **Found, not fixed.** `System.out.println(x.length(;` followed by a statement leaves the parentheses unbalanced, so the next line is still syntactically inside the argument list and statement-site completion returns nothing. That is site classification under unbalanced parens (the dummy-identifier / paren-repair heuristics), not locals. `if (a.\n a.` is genuinely `a.a.` in Java and is not a bug.
