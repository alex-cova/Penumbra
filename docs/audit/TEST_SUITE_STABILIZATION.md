# Test suite stabilization

Measured on this machine on 2026-11-11. HEAD `03c059d627e71f65296794b5da350183fccb0a6d`. The working tree already held unrelated Git UI edits; those files were not part of this pass. No commit was created. JaCoCo jars stay in gitignored `build/` and are not committed.

## Environment

| Item | Value |
|---|---|
| macOS | 27.2 (26B123) |
| Swift | 6.4.2 (swiftlang-6.4.2.1.9) |
| Xcode | 27.2 (27B52) |
| Git | Apple Git 2.54.0 (Git-157) |
| Java on `PATH` | Temurin 25.0.4.1+1, `JAVA_HOME=/Users/alex/.sdkman/candidates/java/current` |
| `java_home -V` | Temurin 24.0.2 at `/Users/alex/Library/Java/JavaVirtualMachines/temurin-24.0.2/Contents/Home` |
| `TERM` | `dumb` |
| Machine | 10 cores, 32 GB RAM |
| Display | `caffeinate -u -d -i -s` for every suite that drives AppKit |

`swift test` uses the default `--no-parallel`. The two packages have separate `.build` directories, so the root suite and the Umbra suite can run at the same time. Coverage tests need a network the first time they run `fetch.sh`. A JDK with `javac` and `jfr` is required for the real instrumentation tests; without one those tests skip, and that skip is the documented prerequisite.

## Baseline

Commands, started together at `2026-11-11T21:34:25Z`:

```bash
caffeinate -u -d -i -s swift test --xunit-output /tmp/penumbra-baseline/root.xml
caffeinate -u -d -i -s swift test --package-path Umbra --xunit-output /tmp/penumbra-baseline/umbra.xml
```

### Root library

Finished `2026-11-11T21:47:59Z`. Wall clock about 814 s. Test time 804.487 s. Exit code 1.

| | |
|---|---|
| Tests | 5337 |
| Skipped | 27 |
| Failures | 1 (0 unexpected) |

The only failure was `EditorIntelligenceControllerCompletionTests.testPopupIsVisibleInViewportWhenScrolledFarDown`: `contentOffset.y` stayed `0.0` after `scrollRangeToVisible` (the assertion requires it to be greater than `1000`).

Two `JavaInstrumentationRealJDKTests` coverage cases skipped because `jacocoagent.jar` and `jacococli.jar` were not on disk: `testCoverageOfAPlainMainEndToEnd` and `testReportWithoutExecutionDataSaysSo`. The other two methods in that class ran. `JavaGoToImplementationTests`, `RecentFilesSwitcherTests`, and `JavaScopeTreeTests.testLargeFileBuildsQuickly` passed in this run. Older notes that list them as failures describe an earlier tree, not this baseline.

### Umbra

This run did not finish. `GhosttyPtyProcessTests.testTermSet` failed after 15 s: the child printed the inherited `TERM=dumb` instead of `xterm-256color`. The process then stopped inside `IDEAgentCommandRunTests.testACustomCommandSendsItsExpansionAndShowsWhatWasTyped`, on the main thread in `NSAlert.runModal` (`IDEAlert.present` → `IDEWorkspace.agentConfirmSkillTools`). The test process was killed so the modal would release. Exit code 1 at `2026-11-11T21:55:35Z`. Umbra totals from this run are not a measurement.

An earlier run the same day, same HEAD, recorded in `docs/audit/git/GIT_FINAL_VERIFICATION.md`: 2893 tests, 37 skipped, 15 issues in 9 methods, exit 1. That inventory matched the code at the start of this pass. It is the list that was fixed, not a second measurement of this session's killed run.

## Failure inventory and root causes

### Completion popup stays at the top — production defect

`scrollRangeToVisible` lays out the visible lines and then clamps the offset to `maximumContentOffset`. `contentSize` is published on the next main-queue turn so a layout pass does not mutate scroll metrics. The popup test lays out and scrolls in the same turn, so the clamp still sees an empty content size and the offset stays `0`.

`justScrollRangeToVisible` now calls `syncContentSizeIfNeeded()` before it clamps, the same synchronous publish `scrollRangeToCenter` already used. The `1000` point threshold is unchanged.

That publish also makes the ordinary reveal path scroll when typewriter anchoring is off. `testTypewriterRequiresAutomaticScrollEnabled` had expected the offset to stay `0` for a caret on line 25. That only held while the clamp still saw an empty content size. With a real content size, automatic scroll disabled means "do not pin the caret", and the ordinary reveal still brings an off-screen caret into view. The test now requires the caret inside the viewport and not on the typewriter pin.

- `Sources/Penumbra/TextView/Core/TextView.swift`
- `Tests/PenumbraTests/EditorIntelligenceControllerCompletionTests.swift`

Focused result: `testPopupIsVisibleInViewportWhenScrolledFarDown` passed (0.275 s). `TextViewContentOffsetClampTests` (2 tests) passed.

### JaCoCo jars missing — infrastructure

`JavaCoverageToolchain.locate` throws `notBundled` when `jacocoagent.jar` and `jacococli.jar` are absent. `Umbra/Package.swift` copies them into the bundle only when they exist at package-evaluation time. The source-tree lookup still finds `Umbra/Sources/Umbra/Tools/JaCoCo/build` after a download, so a test does not need a rebuild to see jars fetched in `setUp`.

Both suites' `setUp` runs the existing `fetch.sh` (JaCoCo 0.8.15, SHA-256 checked, 180 s timeout) through `SubprocessKit`. If the jars are still missing, the coverage tests fail instead of skipping. The fake-directory test `testTheJarsAreFoundInEachLayoutAnAppCanHave` still expects `notBundled` for empty directories. `testThePackagedAppHasTheJarsWhereTheLookupLooks` still skips unless `UMBRA_PACKAGED_APP` points at a built app. JDK-missing skips are unchanged.

- `Umbra/Tests/UmbraTests/IDEInstrumentedRunWorkspaceTests.swift`
- `Tests/PenumbraTests/JavaIntelligence/JavaInstrumentationRealJDKTests.swift`
- `CONTRIBUTING.md`

Focused result: all 4 `JavaInstrumentationRealJDKTests` passed, including the two that had skipped. The Umbra instrumented class ran with one intentional packaged-app skip and zero failures.

### `TERM` inherited from the parent — production defect

`GhosttyPtyProcess` is a PTY. Its `TERM` and `COLORTERM` name that terminal, not the process that spawned it. An agent shell is often `TERM=dumb`. The child was keeping that value whenever the parent had one, and only defaulted when both the override and the parent left `TERM` unset.

`spawn` now drops `TERM` and `COLORTERM` from the parent environment, then applies the caller's `environment`. A non-empty override wins. An absent or empty value becomes `xterm-256color` and `truecolor`. Other variables still inherit. `IDETerminalLaunch` already passes the settings value. `IDEAgentCommandRunner`'s deliberate `TERM=dumb` is a different process and was not changed.

Tests cover the inherited `dumb` parent, an unset parent, an explicit `xterm-kitty` / `24bit` override, and an empty override. `testTermSet` still expects `xterm-256color` with no override.

- `Umbra/Sources/Umbra/Terminal/GhosttyPtyProcess.swift`
- `Umbra/Tests/UmbraTests/GhosttyPtyProcessTests.swift`

Focused result: every `GhosttyPtyProcessTests` method passed, including `testTermSet` (0.106 s; the baseline failure waited 15 s).

### Settings page order — outdated expectation

`IDEPreferencesDomain.leading` is general, editor, saving, appearance, terminal, focus, project. `ordered(with:)` appends module pages and then agent. The Terminal page is intentional. The test expected the list from before that page existed.

The assertion now includes `terminal` between `appearance` and `focus`. Java remains between project and agent. `IDETerminalSettingsTests.testTheTerminalPageSitsAfterAppearance` and `IDEPreferencesKeyboardTests` (moving back from agent lands on project) passed with that order.

- `Umbra/Sources/Umbra/Settings/IDEPreferencesDomain.swift` (unchanged)
- `Umbra/Tests/UmbraTests/IDELanguageModuleTests.swift`

### Language registry includes Python — outdated expectation

`IDEIntelligenceServices` registers Java, TypeScript, Swift, SourceKit, the TypeScript server, then the Python language server, then markdown, SQL, HTTP, JSON, and injection. Registration order is the provider order. The first service that claims a language wins. Python's policy disables snippets, symbol hover, and symbol navigation. It does not disable duplicate-symbol diagnostics.

The two registry tests still listed the pre-Python providers and opt-out sets. They now expect Python in that order and in those three opt-out sets. `duplicateSymbolDiagnostics` stays `http` and `swift`. Order assertions stayed exact.

- `Umbra/Sources/Umbra/Intelligence/IDEIntelligenceServices.swift` (unchanged)
- `Umbra/Tests/UmbraTests/LanguageServiceRegistryTests.swift`

Focused result: `LanguageServiceRegistryTests` 29 tests, 0 failures, including `testUmbraRegistryKeepsTheEngineProviderOrder` and `testUmbraRegistryOptsOutOfTheSameGenericFeaturesAsBefore`.

### Swift grammar ceiling — production defect

`testRepositorySwiftFilesStayWithinTheSyntaxProblemCeiling` walks every non-hidden `.swift` file outside `.build`, `.git`, `checkouts`, `.swiftpm`, `DerivedData`, `node_modules`, and `SwiftCorpus`. The allowlist is empty. Three files had error nodes:

1. `Tools/PerfHarness/Sources/JavaAllocationProfile.swift` and `Tools/PerfHarness/Sources/CompletionLatencyProfile.swift` contain a local `nonisolated(unsafe) var`. The grammar only allowed `nonisolated` (`unsafe` or `nonsending`) as a member modifier.
2. `Tests/PenumbraTests/JavaIntelligence/Support/ReferenceRepair.swift` calls `open.append` inside a `switch` case. `open` is a visibility modifier, so the next `switch_entry` consumed it and `.append` became an error. Outside a switch the same call already parsed, because a statement can continue when `open` cannot start the next case.

Local declarations now accept the isolation modifier at a lower precedence than a member declaration, so `nonisolated(unsafe) static var` and `open class` stay member and visibility modifiers. A switch case takes attributes (`@unknown default`, `@available`) and not visibility or member modifiers, which matches the language. `open` is also a contextual identifier. `parser.c` was regenerated with tree-sitter-cli 0.26.12 at ABI 15 (`tree-sitter.json` keeps the generator on ABI 15; without it the CLI falls back to ABI 14). `EXTERNAL_TOKEN_COUNT` stayed 35, matching `scanner.c`. The C parser was not edited by hand.

A direct parse of every first-party Swift file the ceiling test considers reported no new error nodes. `open class`, member `nonisolated(unsafe)`, and `@unknown default` still parse.

- `Sources/TreeSitterSwift/grammar.js`
- `Sources/TreeSitterSwift/tree-sitter.json` (new; generator metadata)
- `Sources/TreeSitterSwift/VERSION`
- `Sources/TreeSitterSwift/src/parser.c` and `src/node-types.json` (generated)
- `Umbra/Tests/UmbraTests/Swift/SwiftModelTests.swift` (`testLocalIsolationModifiersParse`, `testASwitchCaseMayCallOpenAndMarkDefaultUnknown`)

Focused result: both new tests passed. The ceiling test passed in 35.982 s.

### Agent confirm hangs the suite — test isolation, with a production guard

A project command that lists `allowed-tools` is untrusted until its fingerprint is stored. `submitWithToolGrant` asks `IDEWorkspace.agentConfirmSkillTools`, which runs `NSAlert.runModal` when there is no window. The expansion test uses a real workspace and never trusted the command, so the suite blocked. A sibling test already trusts its command first.

The expansion test now trusts `fix` before it types `/fix`, and it asserts that the declined-tools notice is absent. `IDEAlert.runModal` and `present` decline immediately when `XCTestConfigurationFilePath`, `XCTestBundlePath`, or the `XCTestCase` class is present, returning the button that is not the confirm button. A destructive confirm (cancel at index 0, confirm at index 1) therefore does not confirm. A single-button notice returns 0. A process that is not under XCTest is unchanged.

- `Umbra/Tests/UmbraTests/IDEAgentCommandsTests.swift`
- `Umbra/Sources/Umbra/SharedUI/IDEAlert.swift`
- `Umbra/Tests/UmbraTests/IDEAlertTests.swift` (new)

Focused result: `testACustomCommandSendsItsExpansionAndShowsWhatWasTyped` passed in 0.080 s. `testACommandsAllowedToolsAreRulesForThatRunOnly` passed. Both `IDEAlertTests` passed.

## Performance

`JavaScopeTreeTests.testLargeFileBuildsQuickly` keeps its 1.0 s Debug budget. The baseline run passed. Root pass 2, sharing the machine with the Umbra suite, measured 1.013 s on the old binary. The cost was quadratic: each of 2,000 fields scanned `stub.fields`, then each stub field scanned every declaration. `buildTypeBody` now indexes fields by name once and records seen names in a set. The budget was not raised. After the index, the case time (parse plus build) was 0.172 s, 0.177 s, 0.175 s in isolation, then 0.175 s and 0.172 s inside the two full suites.

The popup failure was a zero offset, not a timing miss, so its threshold stayed at 1000 points. No timing threshold was changed.

## Remaining skips

No skip was added in this pass. The two JaCoCo coverage skips from the baseline now run.

Root, 25, all opt-in:

| Count | Gate |
|---|---|
| 6 | `SWIFT_PARITY=1` (scorecard and SourceKit ceiling) |
| 4 | `UMBRA_PREVIEW_INTEGRATION=1` |
| 3 | Java call hierarchy fixtures without navigation sources or a full classpath |
| 2 | `JAVA_DIFFERENTIAL=1` / `JAVA_DIFFERENTIAL_REPORT=1` |
| 1 | `PENUMBRA_HIGHLIGHT_STRESS` |
| 1 | `JAVA_QUALITY=1` |
| 1 | `JAVA_PARITY=1` |
| 1 | `JAVA_AUDIT=1` |
| 1 | `LARGE_FILE_MEASURE_MB` |
| 1 | `mvn` is not installed |
| 1 | `SWIFT_INSPECTION_APPLY_FIXES_TO` |
| 1 | `SWIFT_REFACTOR_APPLY_TO` |
| 1 | `UMBRA_JDK_HOME` |

Umbra, 37, listed in the verification section. All require an external tool, a packaged app, a window server, or a local model.

## Verification

### Focused (this session)

| Suite | Result |
|---|---|
| Root filter: popup, content-offset clamp, `JavaInstrumentationRealJDKTests` | 7 tests, 0 failures, exit 0. `2026-11-11T22:21:31Z`–`22:22:02Z` |
| Umbra filter: Ghostty, alerts, registry, Swift model, instrumented runs, settings order, the two command tests | 83 tests, 1 skipped (`UMBRA_PACKAGED_APP` unset), 0 failures, exit 0. Ended `2026-11-11T22:24:35Z` |

The first Umbra focused build failed to compile: `IDEAlertTests` called main-actor `IDEAlert` off the main actor. The class is `@MainActor`. The rerun is the result above.

### Full Debug suites

Umbra pass 1 finished `2026-11-11T22:37:07Z`. Exit code 0.

XCTest: 2901 tests, 37 skipped, 0 failures, in 688.355 s. Swift Testing: `IDEAgentRetryStatusTests`, 3 tests, 0 failures. The eight tests added in this pass (four `TERM` cases, two alert cases, two Swift grammar cases) account for 2901 − 2893.

The 37 skips are the same env-gated cases as before this pass. None are coverage tests.

| Count | Reason |
|---|---|
| 16 | `UMBRA_PREVIEW_INTEGRATION=1` |
| 9 | `UMBRA_UI_TESTS=1` (window server) |
| 4 | `UMBRA_AGENT_OLLAMA_MODEL` |
| 1 | `UMBRA_AGENT_MLX_MODEL` |
| 1 | `UMBRA_TEMPLATE_SAMPLES` |
| 1 | `UMBRA_PREVIEW_IOS_PROJECT`, `_FILE`, and `_TARGET` |
| 1 | `UMBRA_PACKAGED_APP` |
| 1 | `UMBRA_LLDB_DAP=1` (session) |
| 1 | `UMBRA_LLDB_DAP=1` (spike) |
| 1 | `UMBRA_JS_DEBUG=1` |
| 1 | no configured data sources |

Root pass 1 finished `2026-11-11T22:38:26Z`. Exit code 1. 5337 tests, 25 skipped, 1 failure, in 787.396 s. The two fewer skips are the JaCoCo coverage tests, which ran. The failure was `TextViewTypewriterScrollingTests.testTypewriterRequiresAutomaticScrollEnabled`, caused by the content-size publish above.

The corrected typewriter assertion, the popup reveal, and the content-offset clamp tests were re-run together: 24 tests, 0 failures, exit 0, ended `2026-11-11T22:40:01Z`.

Umbra pass 2 finished `2026-11-11T22:49:09Z`. Exit code 0. XCTest: 2901 tests, 37 skipped, 0 failures, in 676.441 s. Swift Testing: 3 tests, 0 failures. Two consecutive green Umbra Debug runs.

Root pass 2 finished `2026-11-11T22:54:12Z` on the pre-index binary. Exit code 1. 5337 tests, 25 skipped, 1 failure, in 821.335 s. The only failure was `testLargeFileBuildsQuickly` at 1.013 s measured (case time 1.081 s).

`JavaScopeTreeTests` on the indexed binary, three runs in a row, each 31 tests and 0 failures:

| Run | `testLargeFileBuildsQuickly` case time |
|---|---|
| 1 | 0.172 s |
| 2 | 0.177 s |
| 3 | 0.175 s |

The case time includes parsing the fixture, so the measured scope-tree build is inside that. The 1.0 s budget was not changed.

Root pass of the fixed binary finished `2026-11-11T23:09:36Z`. Exit code 0. 5337 tests, 25 skipped, 0 failures, in 853.399 s. `testLargeFileBuildsQuickly` passed in 0.175 s.

The repeat finished `2026-11-11T23:22:48Z`. Exit code 0. 5337 tests, 25 skipped, 0 failures, in 771.577 s. `testLargeFileBuildsQuickly` passed in 0.172 s. Two consecutive green root Debug runs of the fixed binary.

Release Umbra build finished `2026-11-11T22:58:42Z`. `swift build -c release --package-path Umbra --product Umbra` completed in 531.08 s, exit 0.

Release Umbra tests of the changed cases finished `2026-11-11T23:11:14Z`. Exit code 0. 76 tests, 1 skipped (`UMBRA_PACKAGED_APP`), 0 failures, in 23.991 s. That filter omits `IDEPreferencesKeyboardTests`, which passed in the Debug focused run and do not contain the changed behavior.

`swift test -c release` on the root package does not compile. Finished `2026-11-11T23:27:15Z`, exit 1, no tests executed. `PenumbraTests` calls TextView hooks that exist only inside `#if DEBUG` (`lineManagerForTesting`, `selectionRectsForTesting`, and the rest). That is pre-existing: Debug builds the hooks, Release strips them, and the test files are not wrapped. It is not caused by the scroll or scope-tree changes. The popup, typewriter, and large-file tests therefore have no Release execution. Their Debug results are the evidence above. The Umbra test target does build in Release, and those tests ran.

### Commands

```bash
caffeinate -u -d -i -s swift test --xunit-output /tmp/penumbra-baseline/full-root-3.xml
caffeinate -u -d -i -s swift test --xunit-output /tmp/penumbra-baseline/full-root-4.xml
caffeinate -u -d -i -s swift test --package-path Umbra --xunit-output /tmp/penumbra-baseline/full-umbra-1.xml
caffeinate -u -d -i -s swift test --package-path Umbra --xunit-output /tmp/penumbra-baseline/full-umbra-2.xml
caffeinate -u -d -i -s swift build -c release --package-path Umbra --product Umbra
caffeinate -u -d -i -s swift test -c release --package-path Umbra --filter 'GhosttyPtyProcessTests|IDEAlertTests|LanguageServiceRegistryTests|SwiftModelTests|IDEInstrumentedRunWorkspaceTests|...'
```

Logs live under `/tmp/penumbra-baseline/`. JaCoCo jars are fetched into gitignored `Umbra/Sources/Umbra/Tools/JaCoCo/build` and are not committed.

## Result

| Metric | Before | After |
|---|---|---|
| Umbra XCTest tests | Not completed (hung). Prior same-HEAD count 2893 | 2901, plus 3 Swift Testing |
| Umbra failures | 1 confirmed, then a hang. Prior inventory 15 issues in 9 methods | 0, two full runs |
| Umbra skipped | Prior inventory 37 | 37, same gates |
| Root tests | 5337 | 5337 |
| Root failures | 1 | 0, two full runs of the fixed binary |
| Root skipped | 27, including 2 missing-jar coverage skips | 25, coverage tests run |
| Release Umbra build | Prior report said it succeeded | Succeeded again, 531 s, exit 0 |
| Release tests | Not run | Umbra changed cases: 76 tests, 0 failures. Root test target does not compile |

No test was deleted. No failure was turned into a skip. The typewriter assertion changed because the reveal now uses a real content size. The 1.0 s scope-tree budget was not raised.
