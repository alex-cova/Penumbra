# F25 — No large-file safe mode

- **Priority:** P2 · **Severity:** Medium · **Confidence:** Confirmed · **Provenance:** B
- **Status:** Open · **Owner:** Unassigned

## Evidence

- Mitigations that exist: mmap-backed piece tree, viewport parse (262,144 UTF-16 window past 1M units), line-controller eviction, 256 KB prefetch. Doc figures (partly stale, pre-mmap-fix): 10 MB open 37 ms / 52 MB RSS, 100 MB 253 ms / 109 MB, 500 MB 5.25 s / 1.42 GB, 2 GB 24.3 s / 4.81 GB.
- `LargeFileOpenTests` covers only a fold-scan guard. There is no size threshold that degrades gracefully — highlighting, folding, indexing, and intelligence all attempt full service until they individually time out or cap.
- Files over 1 MiB are silently skipped by Swift/TypeScript indexing (`maxBytes = 1_048_576`) with no user-visible signal — the same silent-degradation pattern.

## Root cause

Large-file behaviour is emergent from per-feature caps, never designed as a mode.

## Fix sketch

Define thresholds (prompt / degrade / read-only tiers, Sublime-style): above tier 1, disable tree-sitter highlighting + folding + indexing with a visible banner and one-click "enable anyway"; above tier 2, read-only. Surface the existing silent 1 MiB index skip in the same UI language.

## Complexity / Dependencies

M. Re-measure the stale 500 MB/2 GB figures first (F06 infrastructure).

## Acceptance criteria

- Opening a 500 MB file reaches an editable (or explicitly read-only) view within an agreed budget, with the degraded features named in the UI.

## Tests / benchmarks

- LargeFileOpenTests extended to the mode thresholds; PerfHarness open scenario at 100/500 MB.

## Out of scope

Streaming editors for multi-GB files beyond the read-only tier.
