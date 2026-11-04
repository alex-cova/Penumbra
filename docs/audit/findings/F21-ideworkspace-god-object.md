# F21 — IDEWorkspace god object and forced root recompute

- **Priority:** P2 · **Severity:** High · **Confidence:** Confirmed · **Provenance:** A
- **Status:** Implemented as far as the evidence goes (see Implementation notes); the structural refactor beyond two clean seams is deliberately not done · **Owner:** Unassigned

## Evidence

- `IDEWorkspace` (Umbra/Sources/Umbra/Workspace/IDEWorkspace.swift:87-89): `@MainActor @Observable`, 6,065 lines + ~20 extensions, ~30 sub-stores in one body. 123 files consume it via `@Environment`, 160 reference it.
- `IDERootView.body:42-48` deliberately reads epoch/preference properties (`let _ =`) to force root recompute; `.id(workspace.layoutEpoch):96` tears down the editor layout subtree per epoch bump (host cache mitigates pane hosts).
- Mitigations already present: `@Observable` per-property tracking; guarded writes on hot paths (`noteActiveDocumentEdited`, `refreshPresentation`); per-window instances via `WindowGroup`.
- Same disease, smaller: `TextInputView` 5,608 lines, `TextView` 3,718, `EditorIntelligenceController` 3,465. Keymap actions thread 4 layers (Keymap → Dispatcher → `performKeymapAction` → `TextView.perform` → controller → host), silently swallowing unhandled keys.

## Root cause

Workspace state accreted in one observable because every feature needed "just one more" shared property.

## Fix sketch

Extract sub-stores at seams the current work does not touch (start with the least-coupled: appearance/preferences, then problems, then run/agent). Narrow `IDERootView`'s forced reads to a dedicated layout-epoch token. Do not rewrite; do not big-bang.

## Complexity / Dependencies

L, incremental. Each extraction is independently shippable.

## Acceptance criteria

- SwiftUI Instruments: root body evaluations during typing/scroll drop measurably after each extraction; no behaviour change in UmbraTests.

## Tests / benchmarks

- UmbraTests suite; SwiftUI Instruments body counts before/after per extraction.

## Out of scope

Replacing SwiftUI chrome or the AppKit editor host — evidence does not support it.

## Implementation notes

2026-11-03. Measured first, because the brief's acceptance (root body evaluations "drop measurably") assumed the root was re-evaluating during editing.

**The runtime premise does not hold.** `IDEBodyDiagnostics` (a per-view body-evaluation counter, a dictionary increment) and `IDERootViewInvalidationTests` (a real offscreen window, a 3,000-line file, `UMBRA_UI_TESTS=1`) count evaluations while the user edits:

| Event | `IDERootView` | `IDEStatusBarPanel` before | after |
|---|---|---|---|
| typing 40 characters | 0 | 41 | 1 |
| moving the caret 40 times | 0 | 39 | 0 |
| scrolling 60 steps | 0 | 0 | 0 |
| Enter 20 times | 0 | 20 | 0 |
| selecting 20 ranges | 0 | 19 | 0 |

The ~30 forced reads in `IDERootView.body` do not fire during editing: the guarded writes (`noteActiveDocumentEdited`, `refreshPresentation`, `updateStatus`) keep the root quiet, and the toolbar, sidebar, editor layout, terminal and toast views are all at zero too. Structural events cost what they should: opening or switching a tab, toggling the sidebar or the terminal each evaluate the root once. So the root recompute, as a performance problem, was not real; F21's remaining weight is the structural one (maintainability of a 6,000-line observable).

**The one thing that did churn.** The status bar re-evaluated on every keystroke and caret move, because `statusLine`, `statusColumn` and `statusSelectionLength` live on the workspace and the bar read them. They are now in `IDEEditorPosition` (`workspace.position`), the three workspace properties forward to it (and only notify on a change, so no caller or test changed), and the position text is its own view (`IDEStatusPositionLabel`). Result in the table above: the bar's 39/20/19 evaluations per caret, Enter and selection become 0, and typing keeps one (the first edit marks the document modified, which the breadcrumb shows); the label follows every event (40/39/20/19) and never evaluates more than once per event. The mutation check (the panel reading `position.line` again) fails the budgets.

**What I did not do, and why.** No further extraction in this pass. With the runtime reason gone, moving state out of `IDEWorkspace` is a maintainability call, and each cluster has callers across many files. The coupling, by name (rough: a word match, so it includes unrelated uses), to choose from:

| Cluster | properties | `IDEWorkspace*` files | other source files | test files |
|---|---|---|---|---|
| hierarchy pins | 4 | 2 | 2 | 1 |
| editor status (language, encoding) | 2 | 3 | 6 | 3 |
| sidebar and layout | 8 | 2 | 5 | 10 |
| AI mode | 10 | 3 | 10 | 6 |
| run availability | 4 | 5 | 7 | 2 |
| run configurations | 6 | 5 | 12 | 3 |
| debugger view state | 5 | 4 | 17 | 7 |

The hierarchy pins are the least coupled and the obvious next seam; `statusLanguage` is not a status-bar concern (module menus, run availability and structure read it), so it should become "the active document's language" rather than move into the status object. Most of the other sub-stores the brief lists as "30 in one body" are already separate objects (`agent`, `project`, `problems`, `usages`, `runs`, `inspections`, ...).

**Also noted, not fixed:** opening a tab evaluates `IDEEditorLayoutNode` twice and `IDEStatusBarPanel` three times after the breadcrumb and `layoutEpoch` narrowing (was four each); a handful per tab open, not per keystroke. Tab clicks: see Implementation notes. The brief's other items (`TextInputView`, `TextView`, `EditorIntelligenceController` size; the keymap's four layers) are untouched.

**To re-run:** `UMBRA_UI_TESTS=1 swift test --filter IDERootViewInvalidationTests` (needs a window server; prints `ROOTBODY` lines per scenario).

### Second pass: the remaining work

- **Hierarchy pins extracted.** The type and the call hierarchy each kept a list of pinned copies, a selected id and their own pin/unpin/clear logic on `IDEWorkspace` (four properties, two copies of the code). `IDEHierarchyPinSet<Store>` (`Panels/IDEHierarchyChrome.swift`) is that logic once; the workspace holds `typePins` and `callPins`, `visibleTypeHierarchy`/`visibleCallHierarchy` ask the set, and `pinTypeHierarchy` and its siblings shrink to a few lines. Rules kept: only the live view can be pinned; unpinning the shown pin returns to the live view; the tab goes when nothing is left. `IDEHierarchyPinSetTests` (7 tests, including that the two kinds stay apart in a workspace).
- **Unhandled keys are no longer silent.** The claim holds: a key bound to an action that the core, the host and the built-in fallback all decline is swallowed on purpose (so it never becomes text) and left no trace. `TextView.onUnhandledKeymapAction` is called in that branch, with a debug log line. It deliberately does not beep: "no handler" and "a handler found nothing to do" (Next Problem with no problems) both return `false`, and telling them apart needs the handler contract to change. `UnhandledKeymapActionTests` (bound and unhandled: reported and not typed; handled: not reported; unbound: not reported); removing the call fails the first.
- **The order the brief proposed was already done.** "Appearance/preferences, then problems, then run/agent" are all separate stores today (`preferences`, `problems`, `runs`, `agent`, plus `usages`, `testResults`, `coverage`, `inspections`, `project`, `gitStatus` and others).
- **Why no further extraction.** I looked at the next-least-coupled cluster, run availability (`runFileCanRun`, `javaFileCanTest`, `runFileURL`, `activeJavaTestClass`). The properties are written by logic that reaches the workbench, the run providers, the gutter, HTTP and database support and the text view (`IDEWorkspace+RunAvailability.swift`); extracting the four properties alone gains nothing and extracting the logic needs wide dependency injection, with no measured benefit (the root and the chrome are already quiet while editing). The debugger, run-configuration, AI-mode and sidebar clusters are coupled the same way or wider (see the table above). That is a decision to take with a feature in hand, not as a refactor for its own sake.
- **Still true, still not done:** `TextInputView` (5.6k lines), `TextView` (3.7k) and `EditorIntelligenceController` (3.5k) are as large as the brief says; the keymap still threads four layers. `openDocument(from:)` still always calls `rebuildLayoutHosts()` and bumps `layoutEpoch`, so opening a file rebuilds the layout subtree (2 layout-node evaluations, 3 status-bar, 1 root per open; the host cache keeps the editors). Changing that is a behavior risk and was left alone.
- **Tab-click churn (done).** Clicking between open tabs (`selectTab`) used to re-evaluate the root 5 of 6 times and the toolbar 5 of 6. Per-property `withObservationTracking` probes found three causes: the root read `windowTitle` (it moved into `IDEWindowConfigurator`, which reads it in `makeNSView`/`updateNSView`); the toolbar read `tabsByPane.count`, and `tabsByPane` is rewritten on every `refreshPresentation()` (the toolbar now reads `hasMultiplePanes`, set only on a change); and unguarded writes of `activePaneID`, `windowTitle` and `isSettingsVisible` (now guarded). The `_printChanges` attribution to `headerContext` was wrong. Result: a click leaves root, toolbar and layout node at 0; the status bar still evaluates once for the breadcrumb. `testStructuralChangesAndWhatTheyCost` asserts this (it failed with 5 before the fix).
