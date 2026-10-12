# SwiftUI previews in Umbra

Plan to show `#Preview` blocks of the user's SwiftUI code in Umbra, beside the editor, updating as they type, interactive. Status: **P0 done (go); P1 and P2 implemented** (extractor, build plan, host, session, canvas, toolbar, Problems, trust; a save reloads in under a second without a build), with end-to-end tests through the real SubprocessKit runner. Not started: P3 (full input, environment bar), P4. The design follows [k-kohey/axe](https://github.com/k-kohey/axe) (an iOS-simulator tool that does the same thing); P0 proved it on macOS and SwiftPM. Items still marked *(verify)* are untested.

## 1. Goal and non-goals

Goal: open a Swift file containing `#Preview` (or a `PreviewProvider`) in a SwiftPM package, press play (⌘B, like Markdown), see the view on a canvas next to the editor, and see body edits within ~1 s without losing view state. Click, type and scroll in the canvas. Build errors land in the Problems panel.

Not goals: Xcode-project support in P1–P3 (see P4), iOS/watchOS/visionOS previews, Xcode's canvas features (pin across files, variants grid in P1), previews while the project does not compile.

Why not Xcode's engine: it relies on private machinery (`XCPreviewAgent`, the preview registry section, XCBuild thunks) and `CLAUDE.md`'s App Store rule bars private SPI. Everything below is a public API or a compiler feature the user's own build uses.

## 2. How it works

```
 Umbra (app)                                   UmbraPreviewHost (helper process)
 ───────────                                   ─────────────────────────────────
 SwiftPreviewExtractor  ─ #Preview source ┐
 SwiftPreviewThunkGenerator ─ thunk .swift ┼─► swift build (SubprocessKit)
 IDESwiftUIPreviewSession                 │      │ user's package built as is, host
        │  JSON lines over a Unix socket  │      │ linked with one swiftc call
        ├─ load(dylib) ───────────────────┼──────► dlopen(thunk.dylib)
        ├─ render(previewID, env) ────────┼──────► NSHostingView in an offscreen window
        ◄─ frame(IOSurface / PNG) ────────┘        layer.render(in:) → frame
        ├─ event(mouse/key/scroll) ──────────────► NSWindow.sendEvent
```

Three build artefacts:

1. **The user's package, built as it is.** `swift build --scratch-path <cache>/<project-hash> -Xswiftc -enable-testing -Xswiftc -Xfrontend -Xswiftc -enable-implicit-dynamic -Xswiftc -Xfrontend -Xswiftc -enable-private-imports`, with its own scratch path so the normal `.build` is never invalidated. No manifest is edited and no product has to be declared: a standalone build leaves `lib<Target>.a`, `<Target>.o` and `<Target>.swiftmodule` in `swift build --show-bin-path` (proved in P0 follow-up). SwiftPM only lets another package depend on *products*, which is why the host is linked directly instead of through a generated package.
   **The host** is one `swiftc` call (~0.9 s) of `UmbraPreviewHost`'s source (socket loop, window, capture, input injection, the generated wrapper) with `-I <bin> -L <bin> -l<Target>` plus every `lib*.a` of the dependencies, and the `PreviewSupport` dylib (`UmbraReload`, built once per toolchain). Output goes next to the products so `Bundle.module` finds its resource bundles.
2. **A thunk dylib per edit**: for each changed file, an `extension T { @_dynamicReplacement(for: body) … }` with the new source pasted in, plus a main thunk holding `_UmbraPreviewWrapper: View` (the `#Preview` closure) and `@_cdecl("umbra_preview_refresh")`. Compiled with one `swiftc -emit-library` against the built module. This is axe's design (`cmd/internal/preview/codegen/thunk.go`), ported to `NSHostingView`.
3. **Fallback**: when a thunk does not compile or the edit is structural (stored properties, new types, signatures), relaunch the preview app after an incremental `swift build`. The canvas shows "Rebuilding…" and keeps the last frame.

## 3. Components and where they live

| Piece | Location | Notes |
|---|---|---|
| `SwiftPreviewExtractor` ✅ | `Sources/SwiftIntelligence/SwiftPreviewExtractor.swift` | Pure, 11 tests (`SwiftPreviewExtractorTests`). `#Preview` blocks (title, traits, closure and content byte ranges, leading `@Previewable` declarations, line) and `PreviewProvider` types, in source order. Reads `#if`, `@available`, `body:` labels, extensions, and the grammar's second shape for `#Preview(args) { … }`. |
| `SwiftPreviewBuildPlan` ✅ | `Sources/SwiftIntelligence/SwiftPreviewBuildPlan.swift` | Pure. A `Job` (package, target, file, block) in; the four commands (`swift build --target`, `--show-bin-path`, host link, thunk compile), the thunk source (`@_private import`, `@Previewable` state, `#sourceLocation` so errors point at the user's file) and paths out. 10 unit tests. |
| `SwiftPreviewHostSource` ✅ | `Sources/SwiftIntelligence/SwiftPreviewHostSource.swift` | The host, as a string compiled per project. Commands `load`, `render`, `mouse`, `quit` over a Unix socket (protocol in the file's header). |
| `SwiftPreviewSupportSource` ✅ | `Sources/SwiftIntelligence/SwiftPreviewSupportSource.swift` | The module host and thunks share: `UmbraPreview.content()` and the root view. |
| `IDESwiftUIPreviewSession` | `Example/Umbra/SwiftUIPreview/` | Per window: owns the host process (SubprocessKit `SubprocessRunner.start`, interactive stdin not needed; socket for the protocol), build queue, state (`idle/building/ready/failed(diagnostics)`), stale-result dropping by a generation counter. |
| `IDESwiftUIPreviewBuilder` | same | Writes the scratch package, runs `swift build`, then `swiftc` for thunks, through SubprocessKit. Reuses the SwiftPM trust gate (`IDESharedServices.swiftPMTrust`) and `SwiftBuildOutputParser` → `IDEProblemsStore.setBuildDiagnostics(_:source: "swiftui-preview")`. |
| `UmbraPreviewHost` runtime | `Example/UmbraPreviewHost/` (source copied into the generated package; not a separate shipped binary) | `NSApplication` accessory policy, offscreen window, socket server, frame capture, event injection. Small and Foundation/AppKit/SwiftUI only. |
| Canvas view | `Example/Umbra/SwiftUIPreview/IDESwiftUIPreviewCanvasView.swift` | A `SplitPanes` pane **beside** the editor (unlike Markdown/CSV, which cover it). Frame view, preview picker, rebuild/stop, environment menu, status line. |
| Toolbar + View menu + gutter | `IDESwiftModule` (`toolbarItems`, `viewMenuItems`) and the gutter's run-marker path (`IDERunGutterMenu`, `IDESwiftRunProvider.runnableLocations`) | `previewToggle` button for `statusLanguage == "swift"` files that contain a preview; a gutter marker on each `#Preview` line. |
| State | `IDEWorkspace` (`isSwiftUIPreviewVisible`, `swiftUIPreview: IDESwiftUIPreviewSession?`) | Persist visibility/selected preview in `IDEWindowSession`. |
| Settings | Settings ▸ Swift ▸ Previews | Enable, rebuild-on (save / idle delay), default size, scale. |

Everything is in the app layer or `SwiftIntelligence`. `Penumbra` and `EditorIntelligence` are untouched, and no library target links SubprocessKit.

## 4. Host protocol (JSON lines, versioned)

Umbra → host: `hello{version}`, `load{dylibPath, generation}`, `render{previewIndex, size, colorScheme, dynamicType, locale, layoutDirection}`, `event{kind, x, y, buttons, modifiers, characters, scrollDelta}`, `quit`.
Host → Umbra: `ready`, `loaded{generation, ok, error}`, `frame{generation, width, height, scale, surface|pngPath}`, `log{stream, text}`, `crash{signal}`.

Frames: P1 writes a PNG to a temp file and sends the path; P3 moves to an IOSurface shared through XPC if profiling says PNG is the bottleneck. A `generation` on every message lets Umbra drop results for an edit that has been superseded.

## 5. Phases

Sizes are rough ideal days for one person who already knows the codebase.

### P0 — Spike, go/no-go (done 2026-10-11, source in `Tools/PreviewSpike/`)
A toy package (`@State`, a `private` helper type, a non-opaque method) and a generated host app, no Umbra code. Result: **go**, measured on Swift 6.4 / macOS 27, arm64, debug.

| Question | Result |
|---|---|
| (a) The three flags (`-enable-testing`, `-enable-implicit-dynamic`, `-enable-private-imports`) via `-Xswiftc` on a SwiftPM library | Work. Also reaches the dependency's own target, no per-target settings needed. |
| (b) A thunk dylib `dlopen`ed in the running host replaces `body` | Works, for an opaque `some View` getter and for a plain method, and the thunk can read `private` members (`@State private var count`, a `private enum`) through `@_private(sourceFile:) import`. Thunk compile: ~2.4 s cold, **0.49 s warm** (`swiftc -emit-library`, one file). |
| (c) Frame capture from an offscreen window | `NSHostingView.cacheDisplay` and `ImageRenderer` are **not** usable (the first drew no text; the second draws a "no entry" placeholder for real controls). `layer.render(in:)` into a flipped `CGContext` works. The window must have an explicit `appearance` (the system appearance was dark and text rendered white on transparent). Window position (on/off screen, alpha) made no difference. |
| (d) Event injection | `NSWindow.sendEvent` with synthesized `leftMouseDown/Up` toggles a SwiftUI `Button` and updates `@State`. Coordinates are in the hosting view's (flipped) space. |
| (e) State across a reload | `.id(UUID())` on the root works but **resets `@State`**. A wrapper view with a changing token does not re-evaluate the body (inputs unchanged). What works: the thunk body starts with `let _ = UmbraReload.shared.generation`, an `@Observable` in a small support module the host and thunks share; bumping it re-evaluates exactly the replaced bodies and **keeps `@State`** (count stayed 2 across red → green). The first reload after launch still uses `.id` (the original body has no dependency), later ones keep state. |
| (f) `@testable import` of an `executableTarget` | **Not tested.** |

Other findings that change the plan:
- Swift 6.4's SwiftPM builds through the new engine: products are in `.build/out/Products/Debug` (not `.build/debug`), with `PackageFrameworks` and a `<Module>.o`. The builder must ask SwiftPM for the path (`swift build --show-bin-path`) rather than hardcode it.
- The generated package needs a tiny support library (`PreviewSupport`: `UmbraReload`) both the host and thunks link; thunks compile against its `.swiftmodule` and resolve its symbols from the host (`-Xlinker -undefined -Xlinker dynamic_lookup`).
- Frame size: `NSHostingView.sizingOptions = []` and an explicit window content size, or the view auto-sizes to the first content and truncates later ones.

### P1 — Static preview, rebuild per edit (1.5–2 wk)
Done so far: extractor, build plan, host, and `SwiftPreviewPipelineIntegrationTests` (run with `UMBRA_PREVIEW_INTEGRATION=1`, ~12 s): builds a package whose other target is broken, links the host, loads a thunk that reads a `private` type, renders a frame (red title present), clicks a button and sees the frame change. Also done: `IDESwiftUIPreviewSession`, the docked canvas, the titlebar button and ⌘B, Problems and trust (`IDESwiftUIPreviewSessionTests`). Input is done too (P3's mouse, scroll and keyboard; `testTypingAndScrollingReachTheView`: click a `TextField`, type, delete, scroll a `LazyVStack` and see later rows appear). Scroll goes to the `NSScrollView` under the point rather than through synthesized wheel events, which for an offscreen window have no sensible location. Also done: refresh on tab switch (debounced 300 ms) and a gutter eye on each `#Preview` / `PreviewProvider` (`IDERunnableLocation.Kind.preview`).

Executable targets are covered: `swift build --target` of one leaves per-file objects and the `.swiftmodule` in the intermediates and only the linked program beside the products, and the object of the `@main` file defines `main`. `IDESwiftUIPreviewArtifacts` finds them (also the older per-module layout, untested) and drops objects `nm -gU` reports a `_main` for; the thunk's `@testable import` of the executable module works. A rename of the entry point with `-entry-point-function-name` compiles but breaks the program's own link, so `swift build` would report failure.
- `SwiftPreviewExtractor` + tests (`#Preview`, titled, `traits:`, nested, inside `#if DEBUG`, `PreviewProvider`).
- Builder: `swift build` of the user's package into its own scratch path, one `swiftc` link of the host, one run that renders one frame and exits. Trust prompt, cancellation (`Stop`), a log in the Run console.
- Canvas pane, toolbar button, gutter marker, diagnostics into Problems.
- Scope: library targets and `@testable`-importable executable targets in the package; macOS only.
Exit: open a file in a real SwiftPM package of this repo's size, press play, see the view; a compile error shows in Problems with a jump to source; Stop leaves no process behind.

### P2 — Persistent host and reload without a build (done)
Measured: a save of the active file is on the canvas in **~0.75 s** (stamp scan, parse, one `swiftc` for the thunk, `load`, render), against ~10 s for a build.

What shipped is not what was planned, because of a SwiftUI hazard found on the way:

- **In-place replacement was tried and dropped.** `@_dynamicReplacement` of a `body` (the thunk plan above, and what axe does) works until the replaced body has a **different concrete type** than the original: SwiftUI caches a view type's `Body` process-wide on first use, and the next `@State` change aborts inside AttributeGraph (`DebugReplaceableViewChild.updateValue` → `resolve_offset` precondition). Recreating the nodes (`.id`) does not help, because the cache is per type, not per node. P0 never hit it because its first load replaced the body before the type's first use. InjectionIII asks users to type-erase for the same reason.
- **A copy of the file instead.** The thunk of `ThunkMode.copy` holds the active file's current text (its `#Preview` blocks blanked, line numbers kept, `#sourceLocation` mapping errors back) plus the preview content. Its types are new types of a new module, so there is no stale metadata, `private` and `fileprivate` types are in the same file as the content, and a new stored property or a changed signature is no obstacle. Names it declares shadow the module's. `@testable import` of the package module gives it the rest.
- **The ladder.** First build: copy thunk, else the `ThunkMode.imported` thunk (the P1 one, `@_private import`), else an error with the compiler's lines. Later save, while the host runs and no *other* Swift file of the package changed (modification time and size, `stamps`): copy thunk and `load`. If the copy does not compile or load: build the package again. A changed other file, `rebuild()`, or another host: build.
- **State.** Every reload shows new types, so `@State` starts over. The root of the canvas is `UmbraPreviewRoot` of the support module (`UmbraReload.epoch` as its identity, `UmbraPreview.content()` replaced by each thunk), so the host's view hierarchy is created once and only its content changes.
- **Not done here:** keeping `@State` across reloads. It is possible only for edits that keep the body's type (literal-only changes); a token-read in the body proved it works, but detecting "same type" soundly needs more than the token shape, and a wrong guess aborts the host.

Tests: `IDESwiftUIPreviewSessionTests.testASaveIsLoadedIntoTheRunningHostWithoutABuild` (a modifier that changes the type, then further taps; a new stored property; another file changed → build), `SwiftPreviewBuildPlanTests.testCopyThunk…`.

### P3 — Interaction and environment (1–1.5 wk)
- Input: mouse (down/up/drag/move, hover), scroll, key, text input into focused fields; canvas coordinate mapping at retina scale.
- Environment bar: light/dark, Dynamic Type, locale, right-to-left, size (fit / device presets), scale. Sent as `render` parameters; the wrapper applies `.preferredColorScheme`, `.environment(\.dynamicTypeSize, …)`, `.environment(\.locale, …)`.
- Several `#Preview`s in a file: picker, and a grid view reusing the same host (one wrapper per block).
- Frame path: IOSurface if PNG measures slow.
Exit: click-through of a form with a text field and a `List`; resize of the pane re-renders at the new size.

### P4 — Coverage (2–3 wk, each item independent)
- `@Previewable`, `PreviewModifier`, `traits`, `PreviewProvider.previews` groups.
- Resource bundles (`Bundle.module`), asset catalogs in packages, `SwiftData`/`@Query` previews with `.modelContainer`.
- Dependency edits: edit a file the preview depends on (axe's "untracked dependency → incremental reload, else rebuild").
- **Xcode projects**: a project-system claim for `.xcodeproj`/`.xcworkspace` using `xcodebuild -showBuildSettings -json` and a scheme build; the same host, linked differently (inject via the loader approach rather than a generated package). Large; decide after P3 whether it is worth it.
- Multiple Swift toolchains (`xcrun --toolchain`, the project's selected toolchain).

### P5 — Ship (1 wk)
Settings pane, docs (`Example/Umbra/CLAUDE.md` entry, `docs/ADDING_A_LANGUAGE.md` pointer), the first-run guide mention, `Scripts/build-app.sh` embedding of the host runtime source, telemetry-free crash log, a `PreviewHarness` benchmark in `Tools/`.

## 6. Tests

- Pure (SwiftIntelligence): extractor and thunk generator golden tests, edit classifier table tests.
- Umbra: `IDESwiftUIPreviewBuilderTests` with a fake process runner (scratch package contents, argument lists, stale-generation dropping, cancellation), `IDESwiftUIPreviewSessionTests` with a fake host speaking the protocol.
- Integration (opt-in, needs a toolchain and a display): the toy package from P0 under `Tests/…/Fixtures`, run under `caffeinate -u -d -i -s swift test` like the other AppKit tests.

## 7. Constraints and risks

- **Sandbox/App Store**: building and `dlopen`ing user code means a non-sandboxed process with `com.apple.security.cs.disable-library-validation` on the helper only. This is a developer-tool capability; it stays in `Example/Umbra`, is off until the user trusts the project (same gate as SwiftPM), and must not be assumed available in a Mac App Store build. Decide before P5 whether the feature is excluded there.
- **Underscored compiler features** (`@_dynamicReplacement`, `@_private(sourceFile:)`): not Apple SPI, but they can change between toolchains. The rebuild fallback in P1 is the safety net; pin an allow-list of tested Swift versions and fall back when the toolchain is newer.
- **Opaque `some View` in `@_dynamicReplacement`**: axe records the property's type expression in its analysis; the generator must do the same *(P0: works for `body`)*.
- **Build time**: the first preview builds the whole dependency graph; show real progress from `swift build` output, never a spinner without text.
- **Swift concurrency / `@MainActor` isolation** of the user's views inside the host: the host runs on the main thread, thunks are `@MainActor`-annotated where the type is.
- **Memory**: one host process per window, killed after a configurable idle time; bounded cache of scratch packages by project hash.
- **Performance rules**: nothing on the typing, layout or scrolling path. The session is notified of edits through the existing document-change event, debounces, and does all work off the main actor.

## 8. First concrete steps

1. ~~P0 spike~~ done, `Tools/PreviewSpike/`.
2. ~~`SwiftPreviewExtractor` + tests~~ done. Gutter markers and an outline entry can use it as is.
3. `SwiftPreviewBuildPlan` (pure: package root + target + block → the exact `swift build` / `swiftc` argument lists and file contents), then the host runtime, then the session and canvas.
4. Decide the sandbox question in §7 before starting P2.
