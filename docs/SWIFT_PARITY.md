# Swift parity scorecard

Measured against `swiftc`, not by feature lists (roadmap: `docs/SWIFT_INTELLIGENCE_ROADMAP.md`).
Regenerated from `Tests/PenumbraTests/Fixtures/SwiftParityCorpus/baseline.json` whenever it is
ratcheted (`SWIFT_PARITY=1 UPDATE_SWIFT_PARITY_BASELINE=1 swift test --filter SwiftParityCorpusTests`);
do not hand-edit the numbers.

Compiler under test: Apple Swift 6.4. The oracle is `swiftc -emit-sil -Onone`
with `-Xfrontend -debug-diagnostic-names`, so SIL diagnostics such as `missing_return_decl` are
labelled too. Error recall and precision only in this phase.

## Error recall and precision per `swiftc` diagnostic

Recall: the share of `swiftc` errors the native checker reports on the same line. Precision: the
share of native findings `swiftc` agrees with on the same line, per group. Native side today:
`SwiftDiagnosticProvider`, which reports syntax problems only, so every type error is at 0%
until a native rule maps its code to a group.

| key | group | recall | precision | oracle errors | native findings |
|---|---|---|---|---|---|
| `argument_out_of_order_unnamed_named` | arguments | 0% (0/1) | n/a | 1 | 0 |
| `async_expr_without_await` | effects | 0% (0/1) | n/a | 1 | 0 |
| `cannot_convert_argument_value` | arguments | 0% (0/1) | n/a | 1 | 0 |
| `cannot_convert_to_return_type` | type-mismatch | 0% (0/1) | n/a | 1 | 0 |
| `cannot_find_in_scope` | unresolved | 0% (0/3) | n/a | 3 | 0 |
| `cannot_find_type_in_scope` | unresolved | 0% (0/1) | n/a | 1 | 0 |
| `could_not_find_type_member` | no-member | 0% (0/2) | n/a | 2 | 0 |
| `could_not_find_value_member` | no-member | 0% (0/1) | n/a | 1 | 0 |
| `missing_argument_named` | arguments | 0% (0/1) | n/a | 1 | 0 |
| `missing_return_decl` | missing-return | 0% (0/1) | n/a | 1 | 0 |
| `optional_not_unwrapped` | type-mismatch | 0% (0/1) | n/a | 1 | 0 |
| `throwing_call_without_try` | effects | 0% (0/1) | n/a | 1 | 0 |
| `type_does_not_conform` | conformance | 0% (0/1) | n/a | 1 | 0 |

## Valid-corpus false positives

Native error-severity findings on code `swiftc` accepts: **0** (hard gate: 0
for every shipped check).

## Completion corpus

Pass count: **37/54; known gaps by tag: sdk 7, generics 5, self-member 2, access-control 1, argument-labels 1, switch-pattern 1** (`Tests/PenumbraTests/Fixtures/SwiftCorpus`, ratcheted by
`NativeCompletionCorpusTests`; gap tags live in the case files).

Semantic ceiling, the same cases: **53/54** through sourcekit-lsp (Swift 6.4); none inconclusive. The gap between the two numbers is what the
native tier cannot yet answer on its own (`SwiftSourceKitCeilingTests`).

## Not yet measured

- SourceKit-LSP as a second column for diagnostics (completion is measured above).
- Refactoring compile rate (needs the refactoring corpus, roadmap Phase 5).
- Latency gates (need Release PerfHarness runs).