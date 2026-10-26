# Contributing

Thanks for helping with Umbra and Penumbra. This repository holds **Umbra**, a macOS editor
built around a coding agent, and **Penumbra**, the AppKit text engine and IDE-intelligence
libraries under it. Bug reports, fixes, new language support, documentation and ideas are all
welcome.

By taking part you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md). Report security
problems privately, as described in [SECURITY.md](SECURITY.md), never in a public issue.

## Before you start

- **Small fixes** (typos, a clear bug, a missing test) can go straight to a pull request.
- **Larger changes** (a new feature, a new dependency, anything touching the agent's
  permissions, the libraries' public API, or performance-critical paths) deserve an issue
  first, so we can agree on the shape before you spend time on it.
- Look at the existing code before adding to it. The repo has a lot of conventions written
  down in the `CLAUDE.md` files (root, `Umbra/`, and one beside most areas of the code). They
  are written for coding agents but are the best map of the project for people too.

## How the repository is organized

| Path | What it is |
| --- | --- |
| `Package.swift`, `Sources/`, `Tests/PenumbraTests/` | The **libraries** package (macOS 14): `Penumbra`, `EditorIntelligence`, the language packs, `JavaIntelligence`, `SwiftIntelligence`, `TypeScriptIntelligence`, `HexKit`, `GitIntelligence`, `SubprocessKit` |
| `Umbra/` | The **app** package (macOS 26): `Sources/Umbra`, `Sources/UmbraACP`, `Tests/UmbraTests`, the Xcode project |
| `Packages/` | Packages shared by the above: `AgentKit` (the agent harness), `AgentKitMLX`, `AgentKitApple`, `DatabaseKit`, `GitIntelligence`, `SubprocessKit`, `TreeSitter`, `Luna` |
| `Tools/` | `PerfHarness` (release performance CLI) and `AgentEval` (agent evaluator) |
| `docs/` | Design notes and rules, such as [`PERFORMANCE_RULES.md`](docs/PERFORMANCE_RULES.md) and [`ADDING_A_LANGUAGE.md`](docs/ADDING_A_LANGUAGE.md) |

A test goes in `Umbra/Tests/UmbraTests` when it imports `Umbra` or an app-only module
(`AgentKit*`, `DatabaseKit`, `XcodeProjectFormat`), and in `Tests/PenumbraTests` otherwise.

## Setting up

You need macOS 26 and Xcode 26 or later (Swift 6.2) to build Umbra. The libraries alone need
macOS 14 and Swift 6.0.

```bash
git clone https://github.com/alex-cova/Penumbra.git
cd Penumbra
./run.sh                      # build and run Umbra (swift run --package-path Umbra Umbra)
```

Run Java features against a real JDK if you have one; tests that need a JDK, or the JaCoCo
jars (`Umbra/Sources/Umbra/Tools/JaCoCo/fetch.sh` downloads them), skip when it is missing.

## Building and testing

```bash
swift build                                       # the libraries
caffeinate -u -d -i -s swift test                 # library tests
caffeinate -u -d -i -s swift test --package-path Umbra   # Umbra's tests
swift test --filter ClassName                     # one suite
```

**Run the full suites with the display on.** Many tests drive AppKit views, wait for
background parses, and use animations. With the display off or the Mac asleep, waits time out
in bulk and the test process can hang. `caffeinate -u -d -i -s` keeps the display and the
system awake for the run. A failure that passes alone and appears only after the machine
slept is this, not your change.

Other checks that CI runs and you can run locally:

```bash
bash Scripts/check-ios-carryover.sh           # no legacy iOS private-API patterns in the Penumbra sources
Scripts/refuse-paid-test-variables.sh         # CI must never hold keys for paid-API tests
python3 Scripts/sync-umbra-xcodeproj.py --check   # Xcode project in step with Umbra/Package.swift
```

Tests that call OpenAI, Anthropic or an Ollama server are opt-in by environment variable and
cost money. Don't enable them in a pull request.

## Rules that protect the libraries

These are enforced in review because they are easy to break by accident:

- **`Penumbra` stays App Store–safe.** Public Apple APIs only, no private SPI, no `Process`/
  `NSTask` or JIT inside library targets, nothing that assumes the sandbox is off, and no
  hidden network calls or telemetry. If a feature can't be done that way, it belongs in the
  app (`Umbra/Sources/Umbra`) or behind an explicit, user-controlled capability.
- **Dependencies point one way.** `EditorIntelligence`, `JavaIntelligence` and `HexKit` don't
  depend on `Penumbra`. Nothing in the root package depends on `Umbra`, `AgentKit*`, Sparkle,
  SwiftTerm, DiagramKit or `DatabaseKit`. Connect the engine and the intelligence layer only
  through `PenumbraEditorAdapter`.
- **Licenses.** Vendored or added code must be App Store–compatible (no GPL in `Penumbra`).
  Record third-party code in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
- **Performance.** Work per keystroke, layout pass or scrolled frame is bounded by the
  visible rows or the size of the edit, never by the document size. Read
  [`docs/PERFORMANCE_RULES.md`](docs/PERFORMANCE_RULES.md) before touching typing, layout,
  scrolling, rendering, selection, folding, highlighting or `LineManager`. Measure with
  `swift run -c release PerfHarness enter-session synthetic --lines 20000` on the parent
  commit and on your change; Debug timings prove nothing.
- **Swift 6 language mode**, and no `defaultIsolation: MainActor` (the engine's actors and
  background parses must stay nonisolated by default).
- **Generated files.** `Sources/Penumbra/Library/L10n.swift` is generated by SwiftGen from
  `Localizable.strings`; edit the strings, not the Swift.

## Working on the agent

Umbra's agent can run commands and edit files, so changes there get extra care:

- Respect the permission modes (plan / ask / auto), the approval prompts and the project
  trust gate. A change that lets something run without them needs a clear justification in
  the issue and an update to [SECURITY.md](SECURITY.md)'s scope if it moves the boundary.
- Add or update tests with the change. The agent has scripted tasks under
  `Tools/AgentEval`; see its `CLAUDE.md` for running them against a real model.
- Keep secrets out of logs, session files and fixtures.

## Adding a language

Follow [`docs/ADDING_A_LANGUAGE.md`](docs/ADDING_A_LANGUAGE.md): a tree-sitter grammar target,
its queries, a `LanguageService` for intelligence if you add one, and the app's chrome for it.
Attribute any vendored grammar in `THIRD_PARTY_NOTICES.md`.

## Pull requests

1. Branch from the latest `main` and keep one pull request to one problem.
2. Match the code around you: naming, comment density and idiom. Run SwiftLint
   (`.swiftlint.yml`) if you have it.
3. Add tests for new behavior and for the bug you fixed. If you can't test something, say why.
4. Review your own full diff before you ask others to: no credentials, no stray generated
   files, no unrelated formatting changes, no accidental changes to `Package.resolved`.
5. In the description, say what changed and why, how you tested it (the commands you ran and
   the result), and anything you are unsure about. Include before/after screenshots for UI
   changes and PerfHarness numbers for performance changes.
6. Wait for CI and review. Don't push to `main` directly.

The [pull request template](.github/PULL_REQUEST_TEMPLATE.md) walks through these points.

Changes written with a coding assistant are welcome. You are responsible for the diff:
read it, run it, and be able to explain it.

## Commit messages

Use a short imperative subject (about 70 characters), then a body that explains why when it
isn't obvious. Link the issue (`Fixes #123`) where there is one.

## License of your contributions

The project is licensed under the [Apache License 2.0](LICENSE). Under section 5 of that
license, any contribution you intentionally submit for inclusion is licensed under the same
terms, with no extra agreement to sign. Only submit work you have the right to contribute,
and don't copy code you aren't allowed to relicense. There is no CLA and no per-commit
sign-off.

## Getting help

See [SUPPORT.md](SUPPORT.md) for where to ask, what a useful bug report contains, and what to
expect. For a question about how something works, the `CLAUDE.md` file beside the code is
usually the quickest answer.
