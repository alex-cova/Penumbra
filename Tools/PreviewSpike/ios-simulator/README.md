# iOS-simulator host spike (plan §9, S0)

`run.sh` reproduces the measurements in `docs/SWIFTUI_PREVIEW_PLAN.md` §9. Findings:

- A bare `swiftc -sdk iphonesimulator -target arm64-apple-ios18.0-simulator` build plus `codesign -s -`
  is enough; no Xcode project. `simctl install` 0.23 s warm, launch to first PNG 0.97 s including a
  deliberate 0.5 s wait, cold boot of a device 17.7 s (iOS 27.0, iPhone 17, headless).
- **The iOS 27 SDK aborts an app that does not adopt the scene lifecycle**
  (`___UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption`, `EXC_BREAKPOINT`): the host needs a
  `UIWindowSceneDelegate` and a `UIApplicationSceneManifest` in `Info.plist`.
- A simulator process is a Mac process: it connects to a Unix socket on the Mac, writes a PNG to any path
  the Mac user can write, and `dlopen`s a simulator-built dylib by absolute path.
- `UIWindow.drawHierarchy` gives a pixel-exact iOS frame (3x on iPhone 17: 1206 × 2622); the status bar is
  not in it.

## Input (S3.0): `input.sh`, `input-host.swift`

What can a host do about taps, scrolling and typing from inside the app with public API only?
`input.sh [ax-off|ax-on|ax-app|ax-live]` builds `input-host.swift` (a SwiftUI fixture and an in-app
probe), installs it on a device Umbra created (never the user's: it picks the first `Umbra Preview` one),
prints what each route did and leaves frames in the folder it names. Results and the design that follows
are in `docs/SWIFTUI_PREVIEW_IOS_PLAN.md` §3. In short:

- **SwiftUI publishes its accessibility tree only to an app launched with
  `com.apple.Accessibility ApplicationAccessibilityEnabled` on** (`ax-off`: 0 elements; `ax-app`: 45; `ax-live`,
  flipped while the app runs: still 0). With it, `accessibilityActivate()` of the element under a point runs
  buttons, toggles, `NavigationLink`s, toolbar items and a sheet's buttons synchronously.
- Tab bar items and the back button answer `UIControl.sendActions(.touchUpInside)`, not activation.
- Scroll is `setContentOffset` (lazy rows follow); text is `becomeFirstResponder` on the `UITextField` found
  under the point, then `UIKeyInput`.
- Round 2: menu and picker items are reached through the opening button's public `menu`
  (`UIAction.performWithSender`, then `contextMenuInteraction?.dismissMenu()`); `UISlider` and `UIStepper` by
  setting their value and sending `.valueChanged`; swipe actions through `accessibilityCustomActions`.
- No public route: `DragGesture`, long press, `onTapGesture` (also with the button trait), alert buttons
  (`keyCommands` is empty), context-menu items, and a hand-made `UITouch`. The software keyboard is not in
  `drawHierarchy`; sheets, alerts and open menus are.
