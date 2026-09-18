# Umbra

Umbra is a lightweight macOS code editor — Sublime Text–class basics without the weight of a full IDE. It is built on the [Penumbra](https://github.com/alex-cova/Penumbra) text engine (tree-sitter highlighting, multi-cursor editing, optional Metal rendering) and ships as a native AppKit app from this repository.

## Download

Pre-built releases are published on [GitHub Releases](https://github.com/alex-cova/Penumbra/releases) as `Umbra-<version>-macOS.zip`.

1. Download and unzip the archive.
2. Move `Umbra.app` to Applications (or anywhere you like).
3. Open Umbra. Signed/notarized builds launch without Gatekeeper workarounds.

## Features

**Editing**
- Tree-sitter syntax highlighting (Swift, JS/TS, Python, JSON, YAML, HTML, Markdown, and more)
- Line numbers, code folding, word wrap, minimap
- Multi-cursor editing, column selection, find/replace
- Optional Metal renderer for large documents

**Project & files**
- Open Folder with a file-tree explorer sidebar
- New / Open / Save / Save As, recent files, drag-and-drop
- Quick Open (⌘P) searches project files and open tabs

**Intelligence (no LSP)**
- Symbol index–driven completion, hover, and diagnostics
- Go to Symbol (⌘R) and symbol-based go to definition
- Snippet and in-buffer word completion

**Workbench**
- Split editors (horizontal/vertical), tabbed panes
- Command palette (⌘⇧P), go to line (⌘G)
- Session restore: tabs, splits, caret, and last project folder

## Keyboard shortcuts

Umbra uses the **Sublime** keymap by default (change in Settings → Keymap).

| Shortcut | Action |
|----------|--------|
| ⌘N | New file |
| ⌘O | Open file |
| ⌘⇧O | Open folder |
| ⌘S / ⌘⇧S | Save / Save As |
| ⌘W | Close tab |
| ⌘P | Go to file |
| ⌘⇧P | Command palette |
| ⌘G | Go to line |
| ⌘R | Go to symbol |
| ⌘F / ⌘⌥F | Find / Replace |
| ⌘\\ | Split editor right |
| ⌘B | Toggle sidebar |
| ⌘, | Settings |

## Development

From the **repository root** (not this folder):

```bash
swift run Umbra
./run.sh
./run-metal.sh              # release build + Metal renderer
swift run Umbra --open path/to/file.swift
```

`swift run` is convenient for hacking on the editor, but it does not install the app icon or bundle metadata — use the release build script for a real `.app`.

### Project layout

```
Example/
├── Umbra/               # App source — SwiftUI shell, views, IDEWorkspace, and UmbraApp.swift (@main)
├── Umbra.xcodeproj/      # Thin Xcode project for Previews/Run/Debug (dev convenience, not for release)
├── umbra.icon/           # App icon (Icon Composer); compiled at build time
└── Resources/             # Info.plist, entitlements
```

The SPM executable target is named `Umbra` in the root `Package.swift`; it's what
`Scripts/build-app.sh` and CI build for release.

### SwiftUI Previews

A SwiftUI Preview hosted inside a SwiftPM executable target fails with *"needs the build setting
`ENABLE_DEBUG_DYLIB` set to `YES`"*, because SwiftPM executables can't produce the debug-dylib split
Previews require — regardless of which file you're previewing. To preview any view in `Example/Umbra/`
(e.g. `IDEPreferencesView.swift`), open **`Example/Umbra.xcodeproj`** and select the `Umbra` scheme —
a thin Xcode app project that compiles the same source files directly as a real app target, which gets
`ENABLE_DEBUG_DYLIB` for free. It also gives you ⌘R to run/debug a real bundle. It's a dev convenience
only — it doesn't build or ship the release `.app`.

Previews fail under the package's `Umbra` or `Penumbra-Package` schemes by design — both run the
SwiftPM executable.

## Building `Umbra.app`

```bash
./Scripts/build-app.sh
```

This script:

1. Builds the `Umbra` target in release configuration.
2. Assembles `dist/Umbra.app` (bundle ID `com.umbra.editor`).
3. Compiles `Example/umbra.icon` via `actool` into `Assets.car` (macOS 26+ Liquid Glass) and `umbra.icns` (fallback).
4. Writes `dist/Umbra-<version>-macOS.zip`.

Open the result:

```bash
open dist/Umbra.app
```

### App icon

The icon lives at [`umbra.icon`](umbra.icon/) (Apple Icon Composer format). Edit it in Icon Composer, then rebuild — `build-app.sh` picks it up automatically. Do not hand-edit generated `Assets.car` or `umbra.icns` in `dist/`.

### Code signing and notarization

For local signed builds, set:

| Variable | Purpose |
|----------|---------|
| `CODESIGN_IDENTITY` | Developer ID Application identity |
| `APPLE_ID` | Apple ID for notarization |
| `APPLE_NOTARIZATION_PASSWORD` | App-specific password |
| `APPLE_TEAM_ID` | Team ID |

CI releases use `.github/workflows/release-app.yml` with the secrets documented in the table above (`APPLE_CERTIFICATE_BASE64`, `KEYCHAIN_PASSWORD`, etc.).

Trigger a release by pushing an unprefixed semver tag (this repo does not use a `v` prefix):

```bash
./Scripts/push-version.sh          # bump VERSION, commit, tag, and push
# or:
git tag 1.4.0
git push origin 1.4.0
```

## Settings & session

Preferences (⌘,) persist font size, tab width, wrap, line numbers, folding, minimap, Metal renderer, and keymap preset.

Editor state is saved to:

`~/Library/Application Support/com.umbra.editor/session.json`

## System requirements

- macOS 12.0 or later
- Xcode command-line tools (for `swift build` and `actool` when building the app icon)

## License

Umbra is part of the Penumbra repository; see the root [LICENSE](../LICENSE) and [README](../README.md) for the library and its terms.
