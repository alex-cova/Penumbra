# Final verification

The implementation is present in the workspace and uncommitted. Existing project build scripts were left untouched. The full approved release-app and compatibility acceptance matrix remains open.

## Test results

| Check | Result |
| --- | --- |
| Pre-change targeted suite | 24 passed, 0 failed. |
| Gradle core | 39 existing XCTest cases and 8 Swift Testing cases passed in the targeted run. |
| SubprocessKit | 53 XCTest cases and 1 streaming sink case passed. |
| Umbra targeted suites | 43 tests passed, including the live-journal integration test. The cancellation test also verifies the workspace reservation through drain. |
| Real Gradle fixture | 24 scenarios passed across three Gradle releases. Nine Gradle exits were intentionally nonzero and were verified against the exact failing tests. An additional Gradle 9.9.2 edge run passed worker exit, build-cache restoration, client cancellation and recovery checks. |
| 1 MiB to 1 GiB component logs | Raw export byte comparison passed at every input size. |
| 100,000 test nodes | All 200,000 start/finish records decoded and 100,000 terminal nodes reconciled in 0.974 s. Process peak RSS was 241.47 MiB. |
| Release app Instruments, keyboard and VoiceOver | Unverified. Component results do not establish renderer or app targets. |

Early verification caught an intentional Stop state change, a filesystem alias issue under `/tmp`, and autorelease retention during export. The reservation now outlives the visible active state. Report ownership uses canonical filesystem identities even before Gradle creates a report directory. Bounded autorelease scopes keep each export block reclaimable.

## Verified matrix

| Gradle / launcher JDK | Java + JUnit 4, duplicate classes, parallel workers, included build | Java + JUnit 5 JVM Test Suite | Retry and caching |
| --- | --- | --- | --- |
| 7.6.4 / Corretto 17.0.18.9.1 | Passed | Passed | Two separate method retries, complete rerun, up-to-date and configuration-cache reuse passed. |
| 8.14.5 / Oracle 21.0.11 | Passed | Passed | Same checks passed. |
| 9.9.2 / Oracle 21.0.11 | Passed | Passed | Same checks passed. |

The JUnit 5 fixture exercised parameterized, repeated, nested and dynamic tests. The two granular retries for each version asserted the exact method and task that executed. The included build fixture verified listener identity. Included-build granular selector replay remains unsupported. Kotlin syntax discovery passed deterministic tests. Kotlin JVM build execution, TestNG, Spock and Spring Boot integration remain unverified. Build-cache restoration, a worker exiting with status 23 and cancellation of a long-running test were verified separately on Gradle 9.9.2. The worker fixture verified Gradle exception evidence. It did not exercise how Umbra renders a crashed worker. The fixtures launched installed Gradle distributions. Exact launcher replay through an actual wrapper and Keychain remains unverified.

## Performance and remaining work

The component benchmark reduced peak RSS from 213.41 MiB to 10.53 MiB at 100 MiB of output. The 1 GiB component peaked at 10.56 MiB. The journal stress test is an offline load. At around 241 MiB for 100,000 nodes, result graph and projection costs deserve separate optimization and an allocation trace. App memory, steady-state footprint, worker footprint, P95 visibility below 100 ms, main-thread work below 4 ms, the 16.67 ms frame budget and ordinary expansion below 100 ms remain unverified. [Performance baseline](PERFORMANCE_BASELINE.md)

The current console uses indexed pages with native per-page selection. Continuous virtual scrolling, persisted decoder checkpoints, byte-range selection across pages and concurrent GUI stress testing remain. Exact retries for parameterized invocations remain disabled. Before-launch steps and debug or coverage configuration are captured for history and require a fresh launch. Gradle result-specific gutter badges, verified replay when source metadata is incomplete, retained historical HTML content, granular included-build replay and automatic comparison of outcomes across retry attempts remain open. See [Implementation phases](IMPLEMENTATION_PLAN.md) for other scope boundaries.

## Changed components

- SubprocessKit gained a throwing streaming sink and bounded pipe read turns.
- JavaIntelligence gained disk logging, incremental diagnostics, the versioned sidecar and journal reader, report provenance, retry planning, encrypted history and Kotlin/JVM declaration discovery.
- Umbra's Gradle project system now owns the task through settlement. Its Gradle console and Test Results panel use the session model. The Maven, Swift and Xcode result paths retain their prior result models.
- The dedicated Gradle path no longer uses unverified XML or fabricated cases from console summaries. The public legacy marker parser and its tests remain for compatibility.
