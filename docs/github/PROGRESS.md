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

## Phase 2 native integration

The service foundation was committed as `b85ce12d`. This increment connects it to Settings → GitHub, the GitHub repository sidebar, and the command palette. The device authorization sheet shows the code, opens GitHub in the system browser, and stops polling when dismissed. Account switching is scoped to the workspace. Where several remotes match, the upstream is preferred and the user can select another fetch remote. The sidebar requests metadata only while visible. Root changes, account switches, and close cancel or invalidate window-owned work.

The repository metadata cache is in memory, private to an account and endpoint, and limited to 128 entries with bounded decoded fields. Reads revalidate with ETags. Unauthorized and inaccessible responses invalidate affected cache entries. Rate-limit responses with GitHub’s throttling headers or HTTP 429 establish an account-scoped hold. The next user-initiated read may proceed after the hold expires. App-owned token rotation, once started, may finish after the only window closes so its rotated token pair can be persisted.

The release build receives the public Client ID as `UMBRA_GITHUB_CLIENT_ID` and the installation slug as `UMBRA_GITHUB_APP_SLUG` through Xcode build settings or the environment passed to `Scripts/build-app.sh`. Both build paths write the public configuration into Info.plist. Configure those values for an Umbra-owned, device-flow-enabled GitHub App with expiring user tokens. Local and CI configurations without a Client ID show a disabled setup state. A release smoke test still needs a signed app, installed GitHub App, and authorized test identities. Automatic discovery covers each workspace's local Git remotes. Enumeration of installation repositories, cross-window request coalescing, shared-config events outside a linked worktree's watched Git directory, and the live accessibility and Keychain checks remain open. Refresh in the sidebar rereads the remote configuration on demand.

| Phase 2 verification | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| Umbra Git, diff, editor cost, workspace lifecycle, settings and sidebar XCTest selection | 296 | 0 | 1 |
| GitHub credential-free fixtures, final rerun | 14 | 0 | 0 |
| Umbra FSEvents and project watcher suites | 9 | 0 | 0 |
| GitIntelligence suite | 6 | 0 | 0 |

The combined run's initial workspace-close fixture used a Git command and output that did not match the existing runner. The final GitHub rerun passed after correcting the fixture. It observed URLSession cancel a suspended metadata request and verified no stale metadata was published. The cache fixture verified account isolation, conditional GET and a hold that prevented a second API request. The XCTest skip was the large-repository Git benchmark, which requires `UMBRA_GIT_COST_REPO`.

Editor-cost fixtures still recorded zero main-thread buffer copies with the same parse and export counts. Median typing cost on this run was 1.23 ms with Structure hidden and 1.31 ms with it visible, compared with 1.22 ms and 1.31 ms on the immediately preceding increment. No live GitHub requests or signed-app Keychain checks were performed. The full Umbra suite was last run on the service increment above.


## UmbraEditor registration smoke test

GitHub issued a device challenge for the UmbraEditor public Client ID with expiring-token scope. The automated challenge was discarded without polling or logging either code. That check did not access user or repository data.

An isolated Developer ID signing probe got `errSecMissingEntitlement` from the data-protection Keychain under Umbra's current unprovisioned signing configuration. The credential store now selects the native file-based Keychain for builds without the required entitlements. A Developer ID probe using the production store passed save, load, update, account listing and removal using synthetic credentials under an isolated service name. Provisioned builds continue using the data-protection Keychain.

The shared Xcode scheme returned “Scheme Umbra is not currently configured for the build action.” The existing SwiftPM app packaging script takes the same two public settings as environment variables, allowing the configured debug app to be built through Umbra's distribution path.

The configured Debug app was packaged, signed with Developer ID, verified with `codesign --verify --deep --strict`, and launched locally. Both public registration values matched the built Info.plist. The GitHub fixture suite passed 14, failed 0 and skipped 0. The user reported that the manual smoke test succeeded in the configured build. The report did not specify whether a private repository was used or whether credentials were restored after restart.
