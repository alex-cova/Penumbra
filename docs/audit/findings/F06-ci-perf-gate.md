# F06 — No CI performance gate; variance unmeasured

- **Priority:** P0 (do first — it makes every other fix measurable) · **Severity:** High · **Confidence:** Confirmed · **Provenance:** A+B
- **Status:** Implemented (see Implementation notes) · **Owner:** Unassigned

## Evidence

- Grep for `PerfHarness|enter-session` in `.github/workflows/` and `Scripts/` returns 0 hits. CI builds and tests only.
- `docs/PERFORMANCE_RULES.md:133-147` mandates Release `enter-session` at 20k + 120k lines before/after hot-path changes; nothing enforces it.
- Prior docs report 8× keystroke variance on same-size files (synthetic-variant warning) and ~2× day-to-day drift.
- PerfHarness already has 25+ commands (`Tools/PerfHarness/Sources/main.swift:27-55`): enter-session, keystroke-budget, scroll-frames, snapshot-metal, java-*/swift-*/ts-*.

## Root cause

Budgets exist as documentation, not as a regression gate.

## Fix sketch

Nightly (or pre-merge, if runtime allows) Release PerfHarness job: `enter-session` 20k/120k + `keystroke-budget`, display-awake runner (`caffeinate -u -d -i -s`), baseline file with tolerance bands accounting for documented drift. Add multi-instance and completion-while-typing scenarios.

## Complexity / Dependencies

M. Depends on a suitable macOS runner with a live display; headless runs flake per CLAUDE.md.

## Acceptance criteria

- A deliberate 2× keystroke regression in a scratch branch fails the gate; reverting passes.
- Baseline + tolerance checked in; results trended per commit.

## Tests / benchmarks

- The gate itself is the test. Validate with one artificial regression.

## Out of scope

Per-PR gating if runtime is prohibitive — nightly is acceptable; no gating is not.

## Implementation notes

Done 2026-11-03 (nightly, not per-PR) — `Scripts/perf-gate.py` (run/check/record), `Scripts/perf-budgets.json` (absolute backstop, 3× time / 1.5× counters), `.github/workflows/perf-gate.yml` (HEAD vs commit ≥24 h old, back to back, separate build paths, median of 3, results uploaded per commit). Pairwise tolerance 1.5× and >50 µs; counters 1.10×. Validated on real harness output with a doctored 2× regression (fails) and an identical pair (passes); the budget check alone does NOT catch 2× (by design, drift). Not validated: the workflow itself on a runner, a real regression in a scratch branch, multi-instance / completion-while-typing scenarios, budgets recorded on a dev Mac (CI runner will likely need re-record).
