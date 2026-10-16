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
| Open → first squiggle, per source (syntax, inspection, javac) | `PerfHarness java-diagnostics latency` | ≤ pass/check time + 50 ms | harness lands in Phase 2 |
| Idle → squiggle, per source | same, typing script then idle | ≤ autoreparse delay + pass/check + 50 ms | harness lands in Phase 2 |
| Warning survival on half-typed files | `PerfHarness java-diagnostics survival <dir\|synthetic>`: inspections on valid text, then inject `foo(` as the first statement of one method, then count findings *outside that member* that survive (shifted) | imports 100% after Phase 1; the rest after Phase 5 | Phase 1 recorded below |
| Squiggle anchoring | Enter-above-warnings script: share of squiggles still covering their original text after each keystroke | 100% outside the edited range | harness lands in Phase 3 |
| Churn | Comment-typing script (no real problem changes): squiggle set changes per burst | 0 | harness lands in Phase 3 |

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
