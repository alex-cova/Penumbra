# PreviewSpike

P0 of `docs/SWIFTUI_PREVIEW_PLAN.md`. Not part of the root package; build by hand.

```bash
cd PreviewApp
swift build -Xswiftc -enable-testing \
  -Xswiftc -Xfrontend -Xswiftc -enable-implicit-dynamic \
  -Xswiftc -Xfrontend -Xswiftc -enable-private-imports
P=.build/out/Products/Debug          # Swift 6.4's build engine; older toolchains use .build/debug
xcrun swiftc -emit-library -module-name ToyKitThunkC -target arm64-apple-macos14.0 -swift-version 5 \
  -I $P -F $P -enable-testing -Xfrontend -enable-private-imports \
  -Xfrontend -disable-previous-implementation-calls-in-dynamic-replacements \
  -Xlinker -undefined -Xlinker dynamic_lookup -o ../thunk/thunkC.dylib ../thunk/thunkC.swift
```

`PreviewApp` reads commands on stdin: `load <dylib>` (dlopen, then a new view identity), `reload2 <dylib>`
(dlopen, then bump `UmbraReload`, which keeps `@State`), `click x,y`, `lsnap <png>`, `quit`.
