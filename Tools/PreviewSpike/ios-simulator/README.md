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
