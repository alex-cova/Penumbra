# SplitView (vendored)

> Copied into Umbra from Hextech (`Hextech/DesignSystem/SplitView`). The notes below describe
> the Hextech port; **Umbra's own changes are listed in the last section.** `SplitPanes` is the
> component to use for every split in Umbra: the workbench shell (`IDERootView`), editor panes
> (`IDEEditorSplitChain`), the debug panel and the source-control list/diff.

Source: <https://github.com/stevengharris/SplitView> — MIT, Copyright (c) 2023 Steven G. Harris.
Full licence text in `LICENSE` beside this file. Vendored rather than added as a package
dependency because the upstream package predates Swift 6 and needs the edits below to build
under this project's settings.

## Why it's here

`HSplitView`/`VSplitView` give no control over the initial divider position, don't persist it,
and can't collapse a pane programmatically. `HSplit`/`VSplit` do all three.

## Edits made to upstream

- **`ObservableObject`/`@Published` → `@Observable`** on `LayoutHolder`, `FractionHolder`,
  `SideHolder`, `SplitStyling`. Required: the `ObservableObject` lint gate in `CLAUDE.md`
  must produce no output. Closure properties and `SideHolder.oldValue` are
  `@ObservationIgnored` — they're plumbing, not render inputs.
- **`@EnvironmentObject` → `@Environment(LayoutHolder.self)`** in `Splitter`, and
  `.environmentObject(layout)` → `.environment(layout)` in `Split`.
- **Two-parameter `onChange`** — the one-parameter form is deprecated on this deployment target.
- **`nonisolated`** on the pure value types (`SplitLayout`, `SplitSide`, `SplitConstraints`),
  per the `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` convention. The explicit `@MainActor`
  annotations upstream carries are dropped as redundant under that setting.
- **`public` dropped** — this is an app target, not a library.
- **`PreviewProvider` blocks removed.** They construct a `Splitter` with no `LayoutHolder` in
  the environment, which now traps rather than falling back.
- **macOS-only cursor handling**; the Catalyst branch is gone.
- **Splitter defaults restyled** to `Theme.quietStroke` at 1pt to match `Divider()` elsewhere,
  instead of upstream's 4pt gray. Invisible (hit-target) thickness lowered 30 → 10pt, because
  at 30 the divider's hit area overlays content on both sides and swallows clicks near a
  pane edge.
- **`Splitter+Extensions.swift` folded into `Splitter.swift`.**

`SplitPanes.swift` is **not** upstream — it's the Hextech bridge. See below.

## Use `SplitPanes`, not `HSplit` directly

`HSplit` constrains panes by *fraction*; every `HSplitView` call site in this codebase
constrains by *points* (`.frame(minWidth: 220)`). `SplitPanes` takes the point minimums and
converts them against the live container size, so a call site keeps its meaning when the
window resizes:

```swift
SplitPanes(minPrimary: 200, minSecondary: 360, storageKey: "classBrowser.split") {
    sidebar
} secondary: {
    detail
}
```

- `storageKey` — persists the divider position across relaunches. Omit for ephemeral splits.
- `priority` — which side keeps its size when the window resizes. Defaults to `.primary`,
  which is what you want for a sidebar; pass `nil` for two equal panes so they scale together.
- `axis: .vertical` covers the `VSplitView` cases.

## Customising the divider

Three levels, cheapest first.

**Tune the stock one.** `HandleSplitter` is the default: a short capsule at the centre of the
seam, tinted just above the background, firming up on hover. Every part of it is a parameter.

```swift
SplitPanes(minPrimary: 280, minSecondary: 280) {
    inputPane
} secondary: {
    outputPane
} divider: {
    HandleSplitter(thickness: 10, handleLength: 48)
}
```

`thickness` is the one with layout consequences — `Split` reads it as the gap reserved between
the panes. `hitThickness` is the invisible drag target; it overlays both panes, so clicks
landing inside it never reach pane content. Keep it near 10.

**Restyle without a new type** — `.styling(color:inset:visibleThickness:invisibleThickness:hideSplitter:)`
on `HSplit`/`VSplit` directly, plus the stock `Splitter.line()` and `Splitter.invisible()`.

**Write your own.** Conform to `SplitDivider`; the entire contract is exposing a `SplitStyling`,
because that's where `Split` reads `visibleThickness` to size the gap. Read
`@Environment(LayoutHolder.self)` if the divider needs to know which axis it's on, and honour
`styling.previewHide` by drawing clear — that's how drag-to-hide previews itself.
`HandleSplitter.swift` is a complete worked example, cursor handling included.

When the container is too narrow to honour both minimums they're scaled down proportionally
rather than fighting each other.

## Known differences from `HSplitView`

- **Two panes only.** Three-pane call sites need nesting, which changes drag semantics: the
  outer divider then resizes pane 1 against *panes 2+3 together*, not against pane 2.
- **No `maxWidth`.** `HSplit` has no equivalent to a pane's maximum, only minimums.
- **No `AXSplitter`.** `HSplitView` bridges to `NSSplitView` and exposes a real splitter
  element to accessibility; this one is a SwiftUI shape with a `DragGesture` and does not.
- **Children get explicit frames** inside a `ZStack`, rather than negotiating their own size.

## Umbra changes (on top of the Hextech port)

- **Explicit `@MainActor`** on `LayoutHolder`, `FractionHolder`, `SideHolder` and `SplitStyling`,
  and `nonisolated` dropped from the value types: the Umbra target builds in Swift 6 mode
  *without* `defaultIsolation: MainActor` (see `Package.swift`), so the default is already
  nonisolated.
- **`Theme` tokens → `IDEAppearance`.** `Splitter` defaults to `ColorToken.border`;
  `Splitter.rule()` is the 1pt rule for two panes inside one island.
- **`HandleSplitter` restyled for the Islands look:** the divider *is* the `islandGap`-wide
  frame-coloured gap, the capsule shows only under the cursor, the hit target is no wider than
  the gap (so the editor's gutter and overlay scroller keep their clicks), and it collapses with
  a hidden pane (`hidesWithPane`, i.e. `styling.hideSplitter`) so a hidden sidebar leaves no
  seam.
- **`Split`: synchronous `onChange(of: size, initial: true)`** instead of `task(id:)`, and zero
  sizes ignored. The task ran after the frame was committed, so a priority side wobbled on every
  live-resize tick.
- **`SplitPanes`:**
  - `onResize(primary, secondary)` reports the settled divider in points (drag end, container
    resize), in the units `idealPrimary`/`idealSecondary` take. Umbra persists sidebar widths
    and the terminal height in `IDESessionStore` through it rather than `storageKey`.
  - The opening width is resolved with `onChange(of: length, initial: true)` instead of
    `task(id:)`, so the first frame isn't drawn at `defaultFraction`.
  - A split positioned only by `defaultFraction` (no ideal size, no `storageKey`) follows changes
    to it, which is how the editor pane chain re-spreads panes evenly.
- **Not copied:** `SplitModifiers.swift` (`.hSplit`/`.vSplit` view modifiers; unused).
