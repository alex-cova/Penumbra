# Java parity scorecard

Measured against `javac`, not by feature lists (plan: `~/.claude/plans/java-intelligence-parity.md`
§2). Regenerated from `Tests/PenumbraTests/Fixtures/JavaParityCorpus/baseline.json` whenever it is
ratcheted (`UPDATE_JAVA_PARITY_BASELINE=1 swift test --filter JavaParityCorpusTests`); do not hand-edit
the numbers. This file also carries the completion-corpus score, replacing the missing
`docs/JAVA_COMPLETION_PLAN.md` the code used to point at.

JDK under test: 27. Error recall/precision only in this phase; type agreement,
refactoring compile rate and latency gates arrive with their phases.

## Error recall and precision per `javac` key

Recall: the share of `javac` errors the native checker reports on the same line. Precision: the
share of native findings `javac` agrees with on the same line. Native side: `unresolved-member`
and `unresolved-type`, both read as the `cant.resolve*` group.

| key | recall | precision | oracle errors | native findings |
|---|---|---|---|---|
| `compiler.err.cant.apply.symbol` | 0% (0/1) | n/a | 1 | 0 |
| `compiler.err.cant.resolve.location` | 17% (1/6) | 100% | 6 | 2 |
| `compiler.err.cant.resolve.location.args` | 100% (1/1) | 100% | 1 | 2 |
| `compiler.err.missing.ret.stmt` | 0% (0/1) | n/a | 1 | 0 |
| `compiler.err.prob.found.req` | 0% (0/2) | n/a | 2 | 0 |
| `compiler.err.unreported.exception.need.to.catch.or.throw` | 0% (0/1) | n/a | 1 | 0 |

## Valid-corpus false positives

Native error-severity findings on code `javac` accepts: **0** (hard gate: 0
for every shipped check).

## Completion corpus

Pass count: **214/253** (`Tests/PenumbraTests/Fixtures/JavaCompletionCorpus`, ratcheted by
`JavaCompletionCorpusTests`; gap tags live in the case files).

## Not yet measured

- Type agreement against `TypeMirror` (needs the `attribute` oracle request and the Phase 4 engine).
- Refactoring compile rate (needs the refactoring corpus, Phase 8).
- Latency gates (need Release PerfHarness runs: native errors for the visible region, warm `javac`
  errors, body re-attribution, completion p95).