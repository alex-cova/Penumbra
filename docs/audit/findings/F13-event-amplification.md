# F13 — Single-event amplification through the adapter

- **Priority:** P1 · **Severity:** Medium · **Confidence:** Confirmed · **Provenance:** B
- **Status:** Open · **Owner:** Unassigned

## Evidence

- Prior audit: one `adapter.events` emission hops to `@MainActor` and triggers 4–5 refreshes (diagnostics, outline, inlay, code vision, bulb), each independently debounced.
- Related confirmed pattern in Umbra: `IDEWorkspace.textViewDidChange:5979` fans out per edit to auto-import, mirror edits, semantic highlight, name index, change markers, structure, autosave — mostly debounced well (e.g. `Debouncer` with text-identity revalidation).

## Root cause

Subscribers react per event instead of per transaction; coalescing is re-implemented (or not) at each consumer.

## Fix sketch

Coalesce per transaction at the adapter: one debounced invalidation carrying the changed ranges/kinds, consumers subscribe to the kinds they need. Keep per-consumer generation guards.

## Complexity / Dependencies

S–M. Coordinate with F22 (watcher fan-out is the same shape one level up).

## Acceptance criteria

- One edit produces one coalesced invalidation in signposts; diagnostics/outline/inlay still update within their existing debounce expectations.

## Tests / benchmarks

- Existing EditorIntelligence controller tests; signpost count per scripted edit.

## Out of scope

Changing debounce intervals without measurement.
