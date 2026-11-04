# F13 — Single-event amplification through the adapter

- **Priority:** P1 · **Severity:** Medium · **Confidence:** Confirmed · **Provenance:** B
- **Status:** ✅ Closed by measurement (2026-11-04): the coalescing already exists at the adapter; no production change, two regression tests · **Owner:** Unassigned

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

## Implementation notes (2026-11-04)

Measured before changing anything; the premise (one emission fans out into four or five uncoalesced refreshes) holds as a description of the code and not as a cost.

- **What the controller receives.** `PenumbraEditorAdapter.textViewDidChange` already coalesces: it schedules one debounced `refreshDocument` (200 ms), which sends one `documentEdited` for the whole burst, and a caret move sends the pair `selectionChanged` + `cursorMoved`. Counted through a second subscription to `adapter.events` in a real controller with counting providers (`EditorEventAmplificationTests`, debug build, headless): one caret move is 2 events; one keystroke is 3 (the pair and one `documentEdited`); 20 keystrokes 30 ms apart are 20 pairs and **1** `documentEdited`.
- **What the providers do.** Each consumer debounces and cancels on its own (breadcrumbs 80 ms, quick-fix bulb 150 ms, inlay hints 250 ms, code vision 400 ms, diagnostics replaced by the next event). Provider calls: one caret move: breadcrumbs 1, bulb 1. One keystroke: diagnostics 1, inlay hints 1, code vision anchors 1, breadcrumbs 1, bulb 2. Twenty keystrokes: the same numbers. The second bulb call is the one that should happen: the first answers the caret move, the second runs after the new diagnostics arrive, and quick fixes depend on them. So there is no per-event amplification of provider work to remove.
- **What the handlers cost.** Handling a caret event on the main actor: 3.3 µs (debug build, 3,000 events), so handling both events of a pair is about 7 µs. `IDEWorkspace.textViewDidChange`, which calls twelve consumers per edit in Umbra, measured 21 µs per call (debug build, a 400-field Java file open in a real workspace; `IDEKeystrokeFanOutTests`). Both are under 1% of the 4 ms keystroke budget even unoptimized, and each consumer only schedules or debounces its real work.
- **Decision.** The brief's fix (coalesce per transaction at the adapter, consumers subscribe by kind) would add an API and a second layer of debouncing to save microseconds, so it was not built. The pair of caret events could be deduplicated in the controller; at 3 µs that is not worth a subtle ordering assumption between two event kinds. If a future consumer does real work per event, the tests below fail first.
- **Tests.** `EditorEventAmplificationTests.testEditsAreCoalescedBeforeTheyReachTheProviders`: limits on provider calls for one caret move, one keystroke and a 20-keystroke burst, and that the edit still reaches diagnostics. Mutation: sending `documentEdited` immediately instead of after the adapter's debounce (`refreshDebouncer.schedule(delay: 0)`) makes diagnostics run 20 times and fails it. `IDEKeystrokeFanOutTests` holds `textViewDidChange` under 500 µs in a debug build.
- **Not done:** the numbers are debug-build and headless; a release run of the window with signposts was not taken, and nothing here changes F22's watcher fan-out (a different path, left for that finding). The related F12 fix (the controller's event task no longer holds the controller) is what makes the consumer set per-window rather than per-process.
