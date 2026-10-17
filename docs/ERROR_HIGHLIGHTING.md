# Error highlighting parity

Goal: the open Java file shows the problems IntelliJ shows, at the same moments,
while typing: instant syntax colour, warnings that survive half-typed code,
compiler errors within a beat of idle, one row per problem, no flicker.

Plan: `~/.claude/plans/pasted-content-id-4cc5-umbra-error-high-spicy-treehouse.md`.
Per-`javac`-key recall and precision stay in `docs/JAVA_PARITY.md`.

## Scorecard

All latencies are medians of ≥ 5 runs on the same machine, Release build, machine
awake (`caffeinate`). Report p50 and max. Identity for churn and survival is
`(source, code, message, severity)`; a pure range shift is not churn.

| Metric | How | Target | Status |
|---|---|---|---|
| Open → first squiggle, per source (syntax, inspection, javac) | `PerfHarness java-diagnostics latency` | ≤ pass/check time + 50 ms | Phase 2 recorded below (warm-`javac` idle half unmeasured here) |
| Idle → squiggle, per source | same, typing script then idle | ≤ autoreparse delay + pass/check + 50 ms | Phase 2 recorded below (warm-`javac` idle half unmeasured here) |
| Warning survival on half-typed files | `PerfHarness java-diagnostics survival <dir\|synthetic>`: inspections on valid text, then inject `foo(` as the first statement of one method, then count findings *outside that member* that survive (shifted) | imports 100% after Phase 1; the rest after Phase 5 | Phase 1 recorded below |
| Squiggle anchoring | Enter-above-warnings script: share of squiggles still covering their original text after each keystroke | 100% outside the edited range | Phase 3 recorded below |
| Churn | Comment-typing script (no real problem changes): squiggle set changes per burst | 0 | Phase 3 recorded below |

## Phase 1: error isolation v1

`JavaInspectionPipeline.inspect` reports unused and duplicate imports from the
well-formed import list even when the tree has a syntax error elsewhere
(`JavaUnusedImports.analyzeToleratingErrors`, diagnostics only — never edits).
Everything semantic stays gated on a clean tree until Phase 5.

Survival (`swift run -c release PerfHarness java-diagnostics survival synthetic --lines 2000`):

| Tree | Imports outside the edited member | All findings outside the edited member |
|---|---|---|
| Parent (`f52a247` + isolation reverted) | 0/2 | 0/958 |
| Phase 1 | 2/2 (100%) | 2/958 (imports only; the rest await Phase 5) |

The surviving 2 are the 2 unused imports; every other rule is unchanged (still
gated on a clean tree). Focused suites: `JavaInspectionPipelineTests` (12),
`JavaUnusedImportsTests` + `JavaInspectionRulesTests` (75) — all green.

## Phase 2: one debounce, zero delay on open

The adapter's content debounce is the only Autoreparse Delay (default 300 ms):
Umbra passes zero to `JavaInspectionService.setIdleDelay` and the Autoreparse
Delay to the compiler's `setIdleDelay`, so open and pane-switch inspection
analyses start immediately and same-text refreshes join the waiting or running
pass/compile instead of restarting it (`pendingHash` on inspections; `force`
is the only restart channel on both). The warm server's zero wait is deferred:
the server backend itself is still unlanded WIP, so this commit keeps one
host-set delay and notes the per-backend split where it will hook in.

`latency` (open simulation) and `typing` (scripted half-typed burst, 8 keys)
harness modes, Release, synthetic 2026 lines, 2 runs each side:

| Mode | Parent (`d8a3af6`) | Phase 2 | Gate |
|---|---|---|---|
| `latency` syntax | 0.0065 s | 0.0047 / 0.0046 s | — |
| `latency` inspection pass | 0.0545 s | 0.0585 / 0.0539 s | open → squiggle ≤ pass + 50 ms |
| `latency` cold-`javac` check | 0.2539 s | 0.2890 / 0.2532 s | — (cold varies ±15% run to run) |
| `typing` inspection median / worst | 0.0064 / 0.0839 s | 0.0063–0.0064 / 0.0807–0.0835 s | idle → squiggle ≤ autoreparse + pass + 50 ms |
| `typing` cold-`javac` (final text) | 0.2554 s | 0.2762 / 0.2607 s | same cold variance |

Scheduling changes pass times by nothing, as expected: the numbers are
identical within run-to-run noise. The warm-`javac` idle column needs the
analysis-server jar plus a synced Gradle project — neither is in this
environment, so that half of the idle gate is unmeasured here.

`enter-session` (no-regression gate), mid-file Enter:

| Lines | Parent | Phase 2 |
|---|---|---|
| 20k | 0.011408 s (live 697) | 0.011506 s (live 697) |
| 120k | 0.011537 s (live 699) | 0.011424 s (live 699) |

Focused suites (133 tests: pipeline, compiler diagnostics, syntax diagnostics,
controller, merger, server, unused imports, rules) — all green, including the
two new same-hash tests (repeated idle refresh starts one pass; same-hash
refresh doesn't restart a running compile, `force` does).

## Phase 3: marker preservation

Squiggles follow edits: `DiagnosticEmphasisController.applyEdit` (same
drop-on-overlap as semantic highlights) runs on every `replaceText`, and the
error stripe reads the live shifted markers instead of its own copy. The
controller merges instead of replacing: reports computed for older text are
dropped by a `contentGeneration` guard, stale sources keep their shifted
markers, fresh results reuse the current marker on content-plus-shifted-range
equality, and an identical report assigns nothing. Freshness rides
`diagnosticsWithFreshness` (default: nothing stale) with unioning in the
engine and the tiered provider; the two Java services override it
(`java-inspection` / `javac` go stale until their pass/compile lands), and a
cancelled inspection pass publishes nothing. Problems receives fresh
diagnostics only, with `staleSources` attached.

Harness (`typing`, Release, synthetic 2026 lines), parent (`afeceab`) vs change:

| Check | Parent | Phase 3 | Gate |
|---|---|---|---|
| Anchoring (survivors covering same text) | 16/16 (1.00) | 16/16 (1.00) | 100% |
| Churn (comment burst, 8 keys) | 0 changes | 0 changes | 0 |
| Typing inspection median / worst | 0.0063 / 0.0817 s | 0.0063 / 0.0814 s | unchanged |

Survivors pre-Phase-5 are the import findings (semantic rules still gate on a
clean tree); per-keystroke shift anchoring is additionally locked by
`TextViewDiagnosticShiftTests` (Enter above warnings shifts squiggles and
stripe ticks; overlapping edits drop; ids survive).

`enter-session` with 500 seeded diagnostics (new `--diagnostics N`), mid-file Enter:

| Lines | Parent | Phase 3 |
|---|---|---|
| 20k | 0.011514 s (live 697) | 0.011901 s (live 697) |
| 120k | 0.011556 s (live 699) | 0.011835 s (live 699) |

Focused suites — controller (16, incl. stale-merge, fresh-replace, clear-by-[],
superseded-generation), shift (3), emphasis unit, both freshness tests, the
superseded-pass test, engine/duplicate-symbol/registry (32), LSP published +
language service, grouping — all green. Each provider keeps its behavior when
fresh (the default freshness path is bit-for-bit the old collection), and a
provider clearing by `[]` still clears, covered by test.

## Phase 4: freshness in the field

`IDEProblemsStore` records per-file stale sources as a superposition over the
unchanged diagnostic buckets: `setStaleSources(_:for:)` (empty clears),
`staleSources(for:)`, cleared with the file, counted in `isEmpty` but never in
badge counts. The workspace feeds it from both paths: the merged editor report
(`applyEditorDiagnostics` passes `report.staleSources` through) and each
service result (`applyCompilerDiagnostics` / `applyInspectionDiagnostics` move
only their own source's flag, measured with `isFresh` against the open
document; a file that is not open leaves the flags alone). The pending-state
panel, the editor widget variant, and the `java-analysis-server` round-trip
need the unlanded analysis-server and Problems-panel work, so they stay
unmeasured here; the store contract they will consume is locked by
`IDEProblemsStoreTests` (5 tests: superposition without touching rows or
counts, survival across unrelated writes, clear-with-file, flags-only
non-emptiness).

No harness numbers change in this phase (no pass, schedule, or render path
moves): survival, latency, typing, anchoring, and churn were re-run against
the Phase 3 parent while landing and are identical; `enter-session` is
untouched.

## Phase 5: semantic rules on broken trees

The broken-tree path now reports more than imports. When the strict context
fails, the pipeline builds a tolerating one (`JavaInspectionContext`
`toleratingErrors`, which succeeds on broken trees): the stub builder, the
walker and the symbol tables walk by expected node type, so they skip `ERROR`
subtrees by construction and stay trustworthy for well-formed regions. On it
run unused/duplicate imports, `class-file-name-mismatch`, and the node rules
in `JavaInspectionPipeline.brokenTreeRules`; data-flow, typed, project,
unresolved and `missing-override` never reach the node runner there, so they
stay strict-only by construction. Every finding is then filtered through
`touchesError` (outermost `ERROR`/`MISSING` byte ranges; an empty range only
matches a point inside it, so a finding that merely ends where breakage
starts is kept). Suppression, severities and quiet findings apply unchanged:
the service still runs `finalize` over the broken path's output.

The allowlist is owned by the survival screen (`java-diagnostics survival`
over the parity corpus: 367 files, `foo(` injected into the first method,
4,870 baseline findings outside the edited member). Opening it to every node
rule convicted exactly two: `class-length` (11 inventions — its message
embeds the count, so any added line reinvents it) and
`missing-serial-version-uid` (1 invention — a false `serialVersionUID` fire
on `java.lang.Number`, which declares one at line 125: error recovery had
silently truncated the field table). Both stay out, with the `unused-*`
rules, which read use-completeness the same way. Everything else survives
with zero inventions, including the heaviest table readers
(`local-can-be-final` 2858/2858, `method-length` 23/23 with a stable
message). Per-rule forensics for future screens:
`JAVA_DIAG_SCREEN_DEBUG=1` prints each invented finding with file, range and
message. New absence-style or count-message rules join `brokenTreeExclusions`,
not the allowlist, until the screen clears them.

Survival (Release, parity corpus), parent (`391997c`) vs Phase 5:

| Tree | All findings outside the edited member | Imports |
|---|---|---|
| Parent | 25/4870 (imports only) | 25/25 |
| Phase 5 | 4796/4870 (98%), 0 invented | 25/25 |

The 74 not surviving are the excluded rules' findings (46: `class-length`,
`missing-serial`, the three `unused-*`), flow/typed rules, which never run
on broken trees (25), and 3 naming-convention findings whose nodes the error
recovery swallowed — fail-silent, never invented. Locked by
`JavaInspectionPipelineTests` (6 new tests:
an allowed node rule and the filename rule survive; each exclusion stays
silent with a valid-text control proving the test is non-vacuous; a finding
inside the `ERROR` range is dropped; `@SuppressWarnings` still silences on a
broken tree).

Perf gates (Release, synthetic 2026 lines / `enter-session` with 500 seeded
diagnostics), parent (`391997c`) vs Phase 5:

| Check | Parent | Phase 5 | Gate |
|---|---|---|---|
| `latency` inspection pass (valid text) | 0.0537 s | 0.0571 s | unchanged (strict path untouched) |
| `typing` inspection median / worst | 0.0064 / 0.0809 s | 0.0629 / 0.0818 s | worst unchanged |
| Anchoring | 16/16 (1.00) | 7705/7706 (1.00) | 100% |
| Churn (comment burst) | 0 | 0 | 0 |
| `enter-session` mid-file Enter, 20k | 11.661 ms | 11.628 ms | unchanged |
| `enter-session` mid-file Enter, 120k | 11.722 ms | 11.534 ms | unchanged |

The typing median rises by design: half-typed keystrokes used to run imports
only (~6 ms), and now run the allowlist — about one strict pass, same budget
as valid text. The worst stays the strict pass, and idle → squiggle still
meets autoreparse + pass + 50 ms. Anchor volume grows (16 → 7706 checked)
because broken trees now carry findings; the single unanchored case is a
finding spanning the caret, whose covered text the keystroke genuinely
changed.
