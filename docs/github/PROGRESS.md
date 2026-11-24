# GitHub integration progress

## 2026-11-24

Phases 0 and 1 delivered the source audit and planning documents before implementation. Phase 2 has a service-layer increment under `Umbra/Sources/Umbra/GitHub/`.

| Slice | Current state |
| --- | --- |
| Device authorization | Fixed GitHub device challenge and exchange routes, injected monotonic clock, polling backoff, cancellation checks, token expiry and refresh, and verified identity lookup. |
| Transport | Ephemeral HTTPS, fixed OAuth and REST authorities, redirect refusal, typed status and decoding errors, and a streaming 2 MiB cap. Repository operations are GET only. |
| Credentials and accounts | Security.framework data-protection Keychain implementation and injectable per-account store, two-account restoration, local sign-out, reauthorization identity check, and single-flight refresh. Signed app Keychain access and sign-out during an in-flight refresh still need verification. Reauthorization is the recovery path if GitHub rotates a token pair but the new pair cannot be persisted. |
| Repository discovery and metadata | Strict GitHub.com fetch URL recognition and typed repository metadata GET. Credentials embedded in remote URLs and repository redirects are rejected. Enterprise authorities are outside the current allowlist. Automatic observation of Git remotes, account/remote selection, installation enumeration, and the repository pane remain open. |
| Remaining foundation | Public Client ID and installation slug from an Umbra-owned registration, sign-in settings, workspace lifecycle integration, cache/revalidation, rate-limit recovery, complete cancellation and stale state checks, signed app verification, and accessibility/UI coverage. |
| Subsequent features | Repository browse/clone/publish, PR management, inline code review, Issues, Actions, notifications, releases, AI workflows, and any second provider are pending. |

## Verification

Swift 6.4.2, Xcode 27.2 build 27B52, arm64 macOS. Initial sandboxed SwiftPM invocations could not write the compiler module cache. The approved retry resolved that restriction.

| Run | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| GitIntelligence, fresh build | 6 | 0 | 0 |
| Penumbra focused Git, gutter, workspace teardown and interaction baseline, prebuilt | 190 | 0 | 0 |
| Umbra focused Git, diff, ACP, and editor-cost baseline, prebuilt | 280 | 0 | 1 |
| First transport/device-flow increment in Umbra's test target, fresh build | 7 | 0 | 0 |
| Updated service-layer tests, isolated temporary Swift package using the same sources and tests | 12 | 0 | 0 |
| Umbra full credential-free selection, binary from first increment | 3,304 | 1 | 60 |
| Umbra rebuilt with the current GitHub, Git, diff, and editor-cost selection | 244 | 0 | 1 |

The full selection excluded `ExternalACPLiveTests` and `IDEConcurrentEditStressTests` as CI does. The one failure was `SwiftModelTests.testRepositorySwiftFilesStayWithinTheSyntaxProblemCeiling`, which flagged the existing `Agent/Schedules/IDEAgentSchedulesSheet.swift`. The test scans the working tree and reported no syntax issue in the GitHub additions.

The final focused run comprised 232 XCTest passes and 12 GitHub Swift Testing passes. The new sources passed Swift 6 complete concurrency type checking with warnings treated as errors.

The Umbra baseline and final focused run skipped the large Git refresh benchmark, which requires `UMBRA_GIT_COST_REPO`. Baseline editor-cost fixtures reported zero main-thread buffer copies. The rebuilt app target also reported zero main-thread buffer copies and the same typing parse and export counts. Median typing cost changed from 1.29 to 1.22 ms with the Structure pane hidden and from 1.38 to 1.31 ms with it visible. The isolated 12-test run took 0.152 s, including an oversized-response fixture. These are fixture timings. A paired runtime network and UI performance profile remains open because workspace integration is pending.

All GitHub cases use scripted Foundation responses and a memory credential store. Live GitHub operations executed 0 tests. Live verification requires an approved Umbra GitHub App registration, installation, and test identities. Signed-app testing requires a verified distribution signature and Keychain access. No Git commits were created.
