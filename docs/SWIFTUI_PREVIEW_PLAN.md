# SwiftUI previews in Umbra

Plan to show `#Preview` blocks of the user's SwiftUI code in Umbra, beside the editor, updating as they type, interactive. Status: **P0 done (go); P1 and P2 implemented** (extractor, build plan, host, session, canvas, toolbar, Problems, trust; a save reloads in under a second without a build), with end-to-end tests through the real SubprocessKit runner. Not started: P3 (full input, environment bar), P4. The design follows [k-kohey/axe](https://github.com/k-kohey/axe) (an iOS-simulator tool that does the same thing); P0 proved it on macOS and SwiftPM. Items still marked *(verify)* are untested. **iOS previews in the simulator: §9 (P6); S0–S2 done, S3–S5 not started and planned in [`SWIFTUI_PREVIEW_IOS_PLAN.md`](SWIFTUI_PREVIEW_IOS_PLAN.md).**

## 1. Goal and non-goals

Goal: open a Swift file containing `#Preview` (or a `PreviewProvider`) in a SwiftPM package, press play (⌘B, like Markdown), see the view on a canvas next to the editor, and see body edits within ~1 s without losing view state. Click, type and scroll in the canvas. Build errors land in the Problems panel.

Not goals: Xcode-project support in P1–P3 (see P4), watchOS/visionOS previews (iOS previews are planned in §9), Xcode's canvas features (pin across files, variants grid in P1), previews while the project does not compile.

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
Done so far: extractor, build plan, host, and `SwiftPreviewPipelineIntegrationTests` (run with `UMBRA_PREVIEW_INTEGRATION=1`, ~12 s): builds a package whose other target is broken, links the host, loads a thunk that reads a `private` type, renders a frame (red title present), clicks a button and sees the frame change. Also done: `IDESwiftUIPreviewSession`, the docked canvas, the titlebar button and ⌘B, Problems and trust (`IDESwiftUIPreviewSessionTests`). Input is done too (P3's mouse, scroll and keyboard; `testTypingAndScrollingReachTheView`: click a `TextField`, type, delete, scroll a `LazyVStack` and see later rows appear). Scroll goes to the `NSScrollView` under the point rather than through synthesized wheel events, which for an offscreen window have no sensible location. The environment bar is done as well (text size, language, right to left, window size; `testTheEnvironmentBarReachesTheView` reads the values the view sees). Also done: refresh on tab switch (debounced 300 ms) and a gutter eye on each `#Preview` / `PreviewProvider` (`IDERunnableLocation.Kind.preview`).

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
- **Sheets and alerts** ✅ (measured on macOS 27, scratch lab, 2026-10-12). A `.sheet` or `.alert` is a window of its own (`SheetPresentationWindow`, `_NSAlertPanel`), so the host window's layer does not hold it, and presenting one makes AppKit move the parent window onto a screen: the preview window, parked at (-20000, -20000), ended up at the bottom-left of the display with the sheet beside it (17 moves during one presentation; 336 samples of a window on a screen at 5 ms, 0 after the fix). `constrainFrameRect` overridden to return its input did **not** stop it; setting the origin back in `NSWindow.didMoveNotification` did, and the sheet follows its parent. The sheet window does not inherit the parent's explicit appearance (it renders in the system one, black text on dark in dark mode), so the host sets it. The host then composites: a dim over the frame, and each sheet's content layer at `sheet.frame` relative to `window.frame` (centred on the window, 240×160 for the lab's sheet), clipped to a rounded rect with a shadow; an alert's content view is not flipped and needs the opposite orientation. Input goes to the topmost sheet with coordinates translated (a synthesized click reached the sheet's button and dismissed it); keys go to its first responder. The sheet attaches about 290 ms after the click and its frame does not change afterwards, so the session draws once more 450 ms after any input (`IDESwiftUIPreviewSession.settleDelay`), which also catches an animation the click started. Not handled: popovers and menus (not measured).
- **Zoom, Content Size and iPhone presets** ✅ (2026-10-12). Zoom is Fit or 25–400% (controls at the canvas's corner, pinch). In the canvas size the window is the panel divided by the zoom, so zooming out makes more of the layout visible instead of scaling a window that cuts the view off (a `#Preview` with `.frame(width: 1100, height: 720)` in a 840-pt panel was cropped at 100%); the render scale is `backing × zoom` there, so the bitmap stays the panel's size, and a host cap of 36 megapixels covers the rest. Content Size asks the host for the view's ideal size: `NSHostingView.fittingSize` is (0, 0) while `sizingOptions` is `[]` (the thunk sets that), (500, 300) for `Color.blue.frame(width: 500, height: 300)` with `.intrinsicContentSize` switched on for the measurement, and the window keeps its size through the switch. A flexible view reports its content (a `Text` 31 × 24, a plain `Color` 10 × 10, a `ScrollView` of 100 rows 46 × 1600), so the result is raised to 44 pt and clamped to 4096. iPhone presets are sizes plus a drawn bezel; the host still renders macOS SwiftUI. A `#Preview` that ends in `.frame(width: 1100, height: 720)` kept that size inside a 440-pt device (measured: the text at the 1100-pt view's left edge was off the frame), so a device or window size leaves that trailing fixed frame out of the thunk's copy of the body, with a note and an override. A device's top and bottom safe areas (59/34 for the 16, 62/34 for the Pro and 17 models, 47/34 for the 16e, 20/0 for the SE) are applied as padding on the root: `safeAreaPadding` did nothing for a `NavigationSplitView`.
Exit: click-through of a form with a text field and a `List`; resize of the pane re-renders at the new size.

### P4 — Coverage (2–3 wk, each item independent)
- `@Previewable`, `PreviewModifier`, `traits`, `PreviewProvider.previews` groups.
- Resource bundles (`Bundle.module`), asset catalogs in packages, `SwiftData`/`@Query` previews with `.modelContainer`.
- Dependency edits: edit a file the preview depends on (axe's "untracked dependency → incremental reload, else rebuild").
- **Xcode projects** ✅ (first slice): `xcodebuild -target` with its own `SYMROOT`/`OBJROOT` and `ARCHS=arm64`, the objects of every target it built linked into the same host, the same thunks. File to target comes from the project model (folder and synchronized-group membership, Sources build phases). Not covered: workspaces, schemes, dependencies that are dynamic frameworks or packages (their objects are linked but frameworks are not found or embedded), per-configuration settings beyond Debug.
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

## 9. iOS previews in the simulator (P6)

Why: a target built for iOS uses API that does not exist on macOS (`Color(.systemGroupedBackground)`, `navigationBarTitleDisplayMode`, `.topBarLeading`, UIKit). The macOS host cannot compile it; since 2026-10-12 it says so (an `iphoneos` target is built with `-sdk macosx`, and a failure names the platform). Rendering such a file needs an iOS process. This is the part of axe's design P0 did not take.

### Spike S0 (done 2026-10-12, `Tools/PreviewSpike/ios-simulator/run.sh`; macOS 27, Xcode 27, iOS 27.0 runtime, iPhone 17)

| Question | Result |
|---|---|
| Is Xcode needed to build the host? | No. `swiftc -sdk iphonesimulator -target arm64-apple-ios18.0-simulator` plus `codesign -s -` on a hand-written `.app` (executable + `Info.plist`). 2.7 s for a small SwiftUI host. |
| Is a bare executable enough (`simctl spawn`)? | Not tried; an app is needed anyway for a scene and a window. |
| Does the iOS 27 SDK accept a plain `UIApplicationDelegate` window? | **No.** It traps at launch (`___UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption`). The host needs a `UIWindowSceneDelegate` and `UIApplicationSceneManifest`. |
| Can the app reach the Mac? | Yes. A simulator process is a Mac process: it connected to a Unix socket on the Mac (path under `/tmp`, short as before), and wrote a PNG to a Mac path from the environment it was launched with (`SIMCTL_CHILD_<NAME>`). |
| Can it load a thunk? | Yes. `dlopen` of a dylib built for `-simulator` by absolute path succeeded. |
| Frame | `UIGraphicsImageRenderer` + `window.drawHierarchy(in:afterScreenUpdates:)`: 1206 × 2622 (3×), iOS fonts, large title, inset-grouped `List`, `systemGroupedBackground` all correct. The status bar is not in it (Umbra draws the bezel anyway). |
| Cost | Cold boot 17.7 s (once per device, headless, no Simulator.app). `simctl install` 0.23 s. Launch to first PNG 0.97 s including a 0.5 s deliberate wait. Whole script, warm: 3.5 s. |

### Design

- **When it applies.** Per target, from `PLATFORM_NAME` (`xcodebuild -showBuildSettings`, already read on failure) or, for a package, the platforms `Package.swift` declares. A target that builds for macOS keeps the macOS host (faster, no simulator, nothing changes). An `iphoneos` target uses the simulator. A package that supports both uses macOS unless the user picks "iPhone" in the Size menu (the preference is per package, in `UserDefaults`). A new `SwiftPreviewBuildPlan.Platform` value (`.macOS`, `.iOSSimulator(deviceTypeID, runtimeID)`) is the one switch; the triple, SDK, product directory and host differ by it.
- **Build.** Xcode target: `xcodebuild -target T -sdk iphonesimulator ARCHS=arm64` with its own `SYMROOT`/`OBJROOT` (products in `Debug-iphonesimulator`, objects in `Objects-normal/arm64`: `knownBinPath` and `locateXcode` take the platform's folder name). SwiftPM: `swift build --sdk <iphonesimulator path> --triple arm64-apple-ios<min>-simulator` *(verify: SwiftPM's cross-SDK build with these flags and the three `-Xswiftc` flags)*. A separate scratch directory per platform, so switching does not discard the other's build.
- **Host.** `UmbraPreviewHost.app` in the work directory: the same single `swiftc` call linking the project's objects, now `-sdk iphonesimulator`, a UIKit `main.swift` (scene delegate, `UIHostingController` as the window's root, same JSON-line protocol and generation rules as the macOS host, same `load`/`render`/`quit`). `Info.plist` with a bundle id derived from the project hash (`com.umbra.preview.<8 hex>`), `UIApplicationSceneManifest`, deployment target from the project (at least the runtime's minimum), ad-hoc signature. The macOS host's source stays as is; the two share the protocol text and the support module's API, not code (AppKit and UIKit differ everywhere that matters). The support module is built per platform (`support-v<N>-ios`).
- **Simulator lifecycle** (`IDESimulatorService`, an actor over `simctl` through SubprocessKit, nothing else in Umbra runs `simctl`). Pick the newest installed iOS runtime that is at least the target's deployment target; if there is none, fail with that sentence and "Xcode ▸ Settings ▸ Components". Use a **device Umbra created** (`simctl create "Umbra Preview — <device type>" …`, found again by name), never the user's: it keeps their state, installed apps and open Simulator windows alone. Boot it headless (`simctl boot`; `bootstatus -b` waits). Umbra shuts down only a device it booted, when the last preview window closes or after an idle time (default 10 minutes, the same setting as the macOS host's), and at quit. The Size menu's iPhone presets stop being drawings: choosing "iPhone 17 Pro" selects that device type (a created device per type, lazily; the booted ones are bounded to two). Boot progress is shown in the panel ("Starting iPhone 17 Pro… first time only").
- **Install and launch.** `simctl install` after each host relink (0.2 s), `simctl launch --terminate-running-process` with `SIMCTL_CHILD_UMBRA_SOCKET=…` and the generation, as for the macOS host (a new host never meets the one it replaces). The launch's process is the `startHost` result, so `onOutput`, `terminate` and "the host stopped" work as today; `simctl launch --console-pty` carries stdout and stderr.
- **Thunks.** Compiled with `-sdk iphonesimulator -target arm64-apple-ios<min>-simulator`, loaded with `dlopen` from the host. The copy-thunk ladder, `#sourceLocation` mapping and the `Job.dropsOuterFrame` rule are unchanged; a reload is a thunk compile plus a `load` into the running app (no relaunch), as on macOS.
- **Frames.** PNG at the device's scale from `drawHierarchy`, written to the frames directory as now. The host window is a real scene window of the device's size, so safe areas, the large title, the keyboard layout guide, `UIScreen.main.scale` and Dynamic Island insets are the system's; the P3 padding workaround (`safeTop`/`safeBottom`) is not used on iOS. Sheets and alerts are presented inside the window's hierarchy, so `drawHierarchy` should include them without the macOS host's compositing *(verify; popovers on iPhone are sheets, on iPad they are views in the window)*.
- **Environment bar.** Dark mode: `window.overrideUserInterfaceStyle`. Text size: `UIContentSizeCategory` through `traitOverrides` (iOS 17+) on the root. Language and right-to-left: the support module's `UmbraEnvironment` as now, plus `semanticContentAttribute` on the window. The device frame (bezel, island) is drawn by Umbra as today, over a frame that is already exactly the device's size.
- **Input** (the hard part; public API only, no `IOHIDEvent`, no private touch injection). The host hit-tests the point in the window and acts on the result: a `UIControl` gets `sendActions(for:)`; a SwiftUI element is activated through `accessibilityActivate()` of the hit-tested accessibility element (buttons, toggles, `NavigationLink`, menu and tab items); a scroll view moves `contentOffset` (clamped, as the macOS host moves a clip view); text goes to the first responder through `UIKeyInput.insertText` / `deleteBackward`. Not covered: arbitrary drag gestures, long press, pinch, swipe actions, pull to refresh *(verify each; `UIAccessibilityCustomAction` covers some swipe actions)*. This is narrower than the macOS host's synthesized `NSEvent`s and the panel says "Limited input (iOS)". If it proves too thin, `simctl`-level touch injection is available only through private frameworks and stays out.
- **Trust and safety.** Same gate as the build that produced the objects (`ensureTrusted()`, folder trust). The user's code runs inside the simulator's runtime but with the Mac's file system and network, which is no stricter than the macOS host; the Settings text says so. Excluded from the Mac App Store build like the rest of the feature (§7).

### Phases

- **S1 — One iOS Xcode target, static frame.** ✅ (2026-10-12) Done as planned, in this order of files: `SwiftPreviewBuildPlan.Platform` (`.macOS`, `.iOSSimulator`; the triple, `-sdk`, products folder, host bundle, thunk's view controller all follow it), `SwiftPreviewIOSHostSource` (UIKit host, scene delegate, `Info.plist`), `IDESimulatorService` (runtimes, devices, create, boot, install, launch; `simctl` through the same runner as everything else), `IDESwiftUIPreviewHostBundle` (the bundle and the built app's resources), and the session's routing (`xcodebuild -showBuildSettings` → `PLATFORM_NAME` and `IPHONEOS_DEPLOYMENT_TARGET`). What it does: an Xcode target whose own platform is `iphoneos` or `iphonesimulator` is built with `-sdk iphonesimulator` in `scratch-ios`, the device is prepared and booted while it builds, the host is linked into `UmbraPreviewHost.app`, signed ad hoc, installed and launched with `--socket`, and frames and the copy-thunk reload work through the same connection and queue as the macOS host.
  - *Measured* (macOS 27, Xcode 27, iOS 27.0, iPhone 17; `IDESimulatorServiceTests`): cold, including creating and booting the device, building the app, installing and the first frame, **21 s**; warm (device booted, project built before), **7 s** from `refresh()` to the first frame, and the edit reloaded into the running app in the same test.
  - *The user's own project* (`SwiftUIExample`: one file with `@main`, `NavigationStack`, `Color(.systemGroupedBackground)`, `.topBarLeading`, a search field): rendered correctly on the first try, with iOS 26's glass toolbar buttons and floating search field. The simulator's own `simctl io screenshot` of the running host matches the frame pixel for pixel in layout, so `drawHierarchy` loses nothing (that file's large navigation title is absent in both).
  - *Findings.* The `@main` object is left out of the link as for macOS (its types are in the copy thunk). A bundle id per work directory leaves one installed app per project on the device. A test run with a temporary directory leaves one each time: they are removed by hand (`simctl uninstall`). The device stays booted after the preview ends (idle shutdown is S5).
  - *Not in S1, and visible (input is S3 below):* mouse, scroll and keys are acknowledged and ignored; the Size menu's presets and the Fit/Zoom controls do not change what the device draws (the window is the device's, `render`'s `width`/`height` are not used; S2 maps presets to device types); Dark mode and text size are passed but not looked at yet (S2).
  - Tests: `SwiftPreviewBuildPlanTests` (iOS argument lists, bundle, thunk, host), `IDESimulatorServiceTests` (catalog, service over a scripted `simctl`, bundle, session routing with a fake simulator, and with `UMBRA_PREVIEW_INTEGRATION=1` a real device; `UMBRA_PREVIEW_IOS_PROJECT`/`_FILE`/`_TARGET` previews a project of your own, `UMBRA_PREVIEW_SNAPSHOTS=<dir>` keeps the frames, `UMBRA_PREVIEW_HOLD=<s>` keeps the app up to compare with `simctl io … screenshot`).
- **S2 — Reload and environment.** ✅ (2026-10-12) The copy-thunk reload was already S1's; S2 measured it and did the rest.
  - *Environment.* Dark mode is `window.overrideUserInterfaceStyle`. Text size and layout direction are **trait overrides on the window** (`traitOverrides.preferredContentSizeCategory`, `.layoutDirection`), so UIKit's own parts follow them as well as SwiftUI, and the support module's `UmbraEnvironment` still carries the locale. Each is measured on a real device in `testTheEnvironmentAndTheDeviceChangeWhatTheSimulatorDraws` (a white page goes below 0.2 mean luminance in dark mode; accessibility-3 text has at least 1.8× the ink; Arabic puts leading-aligned text on the right half) and the frames were looked at.
  - *Devices.* The Size menu is replaced, for an iOS preview, by a **Device** picker of the runtime's own iPhone and iPad types (not the static preset list, which names phones a runtime may not have). A type's bezel is the matching preset's, else a generic modern phone at the frame's size; tablets have none. `IDESimulatorRequest` carries `minimumVersion`, a **pinned runtime** and a device type: moving a running preview keeps the runtime (the host and the objects were compiled for its version) and takes another type; a type the runtime lacks falls back to its default phone. A move needs no build: the host app is installed on that device, launched, and loads the thunk the old one had (`Baseline.thunkPath`, kept up to date by hot reloads). The service keeps at most **two** of its own devices booted and shuts down the oldest. The choice is remembered for the next build.
  - *Size, zoom and windows.* Not applicable to a device window: `fillsCanvas` and `dropsPreviewFrame` are off for the simulator, zoom only scales the frame, and the window sizes and "Keep the Preview's Own Frame" are not offered.
  - *Measured* (same machine as S1): hot reload of an edited file into the running app **0.59 s**; moving to another device that is already booted **1.2 s**; moving to a device that must be created and booted **19 s**; first frame warm **6.7 s**.
  - Tests: the integration test above; unit tests for the request (pinned runtime, type fallback), the booted-device bound, the remembered choice, the bezel and the flags the simulator turns off.
- **S3 — Input.** *(Detailed in `SWIFTUI_PREVIEW_IOS_PLAN.md` §3.)* ✅ built 2026-10-13, not yet run on a device. The spike (S0-style table in the iOS plan) found that SwiftUI publishes its accessibility tree only to an app launched with the device's `ApplicationAccessibilityEnabled` preference on, so `IDESimulatorService.boot` sets it; then tap = text field focus, else `accessibilityActivate()` of the smallest element under the point, else the `UIControl` there (tab bar, back button); scroll and drag = clamped content offset; keys = `UIKeyInput`/`UITextInput` on the first responder. Sheets, alerts and open menus are in the frame; the software keyboard is not. No route: drag and long-press gestures, `onTapGesture` on a non-button, alert buttons, menu items. Panel: "Limited input".
- **S4 — Packages and the picker.** ✅ built 2026-10-13, spike run, rest not yet run on a device. `swift build --sdk/--triple` cross-builds an iOS package (the bin path is `…/out/Products/Debug-iphonesimulator`, and the existing artifact locator reads it); the Device menu has a Mac entry and a package that supports both remembers the choice; a package that declares only iOS goes to the simulator; `Bundle.module` **traps** in an app without its bundle, so the products folder's `*.bundle` directories are copied into the host app; the donor app's `Info.plist` keys that its code depends on (fonts, localizations, usage descriptions…) are merged; a missing module next to a workspace or Podfile is explained. Library targets, packages inside an Xcode project and embedded frameworks are untried.
- **S5 — Ship.** Split in two in `SWIFTUI_PREVIEW_IOS_PLAN.md`. S5a (per-session files, socket and app identifier, device leases and idle shutdown, stale app cleanup, a host that stopped starts again with no build) is built 2026-10-13 and not yet run on a device. S5b (a Settings pane with idle time, simulator start, device families and the list of devices Umbra created; Download-runtime and Open-Xcode remedies; classified failure messages; the Xcode-mismatch check) is built 2026-10-13, also not yet run on a device.

  *Measurements to date* (macOS 27, Xcode 27, iOS 27.0; S0–S2 on iPhone 17, the input spike on iPhone 17 Pro Max). Cold, including creating and booting the device: 21 s. Warm first frame: 7 s (6.7). Hot reload into the running app: 0.59 s. Move to another booted device: 1.2 s; to one that must be created and booted: 19 s. Cold boot of a device: 17–19 s. Accessibility preference write: 0.22 s. Accessibility tree walk: 24 ms for 45 elements. Not measured: input latency in a session, the relaunch of a stopped host, `xcodebuild -downloadPlatform`.

### Risks and open questions

- **Simulator availability.** It needs Xcode and an iOS runtime, a large optional download. Without them the macOS path is the only one and the panel says why.
- **Input breadth** (above). The decision to stay on public API caps interactivity; this is the main reason the phase order puts input after a correct frame.
- **iOS SDK churn.** The scene-lifecycle trap shows the host can break on a new SDK; the opt-in integration test runs against the installed runtime so it is noticed at once. The host is plain UIKit and small.
- **Disk and memory.** A booted device is a few hundred MB resident plus its data directory; created devices are named, listed in the Settings pane and removable there.
- **Concurrent windows.** Two Umbra windows previewing different projects share one device: the bundle ids differ, so both hosts coexist; the boot is serialized in `IDESimulatorService`.
- **Xcode's own previews and the Simulator app** are never touched: no `Simulator.app` window is opened and no existing device is changed.
