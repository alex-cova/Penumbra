# Continuous integration

Workflow: `.github/workflows/editor-ci.yml` ("Umbra CI"). Every job runs on the `xcode-27` runner label with
`DEVELOPER_DIR=/Applications/Xcode_27.0.app/Contents/Developer` (AgentKitApple needs the macOS 27 SDK). The
first steps of each job are the composite action `.github/actions/xcode27-setup` (toolchain report, paid-test
variable refusal, Metal toolchain).

No job uses a secret, an OpenAI or Anthropic key, or a Codex / Claude Code login. The workflow has
`permissions: contents: read`.

## Jobs

| Job | What it runs |
|---|---|
| `build-editor` | Unchanged checks: iOS carryover, design tokens, library build, Java completion tests, release build of Umbra. |
| `agentkit-tests` | `Packages/AgentKit` unit tests. |
| `umbra-tests` | The whole `Umbra` package suite except `ExternalACPLiveTests`, via `Scripts/ci-umbra-tests.sh`, which then fails if any `IDEACP*` suite or `UmbraACPAgentParityTests` skipped or failed a case. |
| `acp-ui-tests` | The 19 `ACPAdapterManagerUITests` XCUITests (`UmbraACPUI` scheme), via `Scripts/ci-acp-ui-tests.sh`. |

The four jobs run in parallel. Caches hold only downloads (SwiftPM repositories, cloned packages, the JaCoCo
jars), never build products.

## What keeps the tests deterministic and free

- **Fixtures.** `--acp-ui-test` (`IDEACPUITestBootstrap`, Debug builds only) serves captured npm documents from
  `Umbra/Tests/UmbraTests/Fixtures/ACPAdapters`, replaces npm with a fake that writes the package tree into a
  temporary prefix, and uses a Node script as the "agent". Each test gets its own adapter root, session
  directory, workspace and `UserDefaults` suite (`ACPUIHarness`).
- **Opt-in live tests are excluded.** `ACPAdapterLiveUITests` (`UMBRA_LIVE_ACP_UI`) is skipped with
  `-skip-testing`; `ExternalACPLiveTests` (`UMBRA_LIVE_ACP`) with `--skip`. `Scripts/refuse-paid-test-variables.sh`
  fails any job whose environment sets those variables, `AGENTKIT_*` keys, or `OPENAI_API_KEY`,
  `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, `CODEX_API_KEY`.
- **Network guard** (`Scripts/ci-network-guard.sh`). After dependencies are built, OpenAI, Anthropic and
  `registry.npmjs.org` hosts resolve to `0.0.0.0` / `::1`, so a live call fails instead of succeeding.
- **Agent tripwire** (`Scripts/ci-agent-tripwire.sh`). Shims named `codex`, `claude`, `codex-acp`,
  `claude-agent-acp`, `npm` and `npx` come first on `PATH` and exit 127 after logging; a poller also records
  any process that looks like Codex or Claude Code. The fixture agent (`node …/node_modules/@agentclientprotocol/*/dist/index.js`)
  is allowed. `verify` fails the job on any record. On a developer Mac that already runs the Codex or Claude
  desktop apps the poller reports their daemons; it is meant for clean runners.
- **User-state guard** (`Scripts/ci-user-state-guard.sh`). Before the tests it records
  `~/Library/Application Support/com.umbra.editor`, the `com.umbra.editor` defaults, `com.umbra.editor*.plist`
  names, the global npm tree and `~/.npmrc`, and points `npm_config_prefix`, `npm_config_cache` and
  `npm_config_userconfig` into the runner's temp directory. After the tests any difference fails the job.
  The harness's own `com.umbra.editor.acp-ui-test.*` suites are excluded (they are the isolation); a run
  that leaves new ones prints a note. Note: `removePersistentDomain` empties those suites but leaves the
  plist files, so they accumulate on a long-lived Mac.
- **No silent skips.** `ACPUIHarness.requireNode()` skips its tests when there is no Node at
  `/opt/homebrew/bin`, `/usr/local/bin` or `/usr/bin`. The job installs Node 22 and links it into
  `/usr/local/bin` when needed, the preflight fails if it is still missing, and `ci-acp-ui-tests.sh` requires
  **19 executed, 19 passed, 0 skipped, 0 failed** from the `.xcresult` summary. When
  `ACPAdapterManagerUITests` gains or loses a test, change `EXPECTED_TESTS` in `Scripts/ci-acp-ui-tests.sh`
  (the script checks the file and tells you).

## Reading a failure

On failure the job uploads `acp-ui-xcresult` (the `.xcresult` bundle and the xcodebuild log) or
`umbra-test-results` for 14 days. Open the bundle in Xcode, or:

```sh
xcrun xcresulttool get test-results summary --path ACPUI.xcresult --format json
xcrun xcresulttool get test-results tests --path ACPUI.xcresult --format json
```

The job summary shows the counts table and, when the failure is a runner limitation, the blocker.

## Running locally

```sh
Scripts/ci-gui-preflight.sh                 # needs a logged-in desktop and passwordless sudo for automationmodetool
Scripts/ci-acp-ui-tests.sh                  # build and run the 19 UI tests
caffeinate -u -d -i -s Scripts/ci-umbra-tests.sh
```

`ci-network-guard.sh` edits `/etc/hosts` and refuses to run outside GitHub Actions.

## GUI automation on hosted runners

`xcode-27` is a GitHub-hosted macOS runner (public preview). Hosted images are not documented to provide a
logged-in console session or an Accessibility grant for Xcode's test runner, and this repository has not yet
run the suite there, so whether `acp-ui-tests` can pass on `xcode-27` is **unverified**. The job is built to
find out without hiding the answer:

1. `Scripts/ci-gui-preflight.sh` checks for an Aqua session on the console, an unlocked screen, that
   `automationmodetool enable-automationmode-without-authentication` works with passwordless sudo, and Node.
   Each failure prints `BLOCKER: …` into the job summary and fails the job.
2. If the preflight passes, the suite is attempted. A log containing `Failed to initialize for UI testing`,
   `Timed out while enabling automation mode`, `Timed out waiting for AX loaded notification`,
   `kAXErrorAPIDisabled`, `is not authorized for accessibility` or `Unable to launch` is reported as
   **"GUI automation unsupported on this runner"** with that line, and the job fails.
3. Anything short of 19/19 passing with zero skips fails the job. The job is never `continue-on-error`.

What the preflight cannot see in advance is the TCC grant itself; that only surfaces when XCTest tries to
drive the app (step 2).

### Proposed self-hosted configuration (not implemented, not required)

If the hosted runner cannot drive the GUI, move only `acp-ui-tests` to a Mac the team controls and leave the
other jobs on `xcode-27`:

- A dedicated Mac (Apple silicon) with Xcode 27, Homebrew Node 22 (`/opt/homebrew/bin/node`), and the
  GitHub Actions runner registered with labels `self-hosted, macOS, umbra-gui` and `--ephemeral` (or a
  cleanup step that removes `$TMPDIR/umbra-acp-ui-*`).
- A dedicated non-admin user with automatic login, no screen saver or lock, display sleep off, and the
  runner started as a LaunchAgent in that user's GUI session (not a LaunchDaemon, which has no window server).
- Passwordless sudo for `/usr/bin/automationmodetool`, and a PPPC/MDM profile (or a one-time manual grant)
  giving **Accessibility** to Xcode's UI-test runner (`Xcode`, `xctest`, and `Umbra-Runner` / the
  `UmbraUITests-Runner` app) so no prompt appears.
- Same variables as above: no secrets, no Codex or Claude installation needed (the tripwire would flag one).
- Change the job to `runs-on: [self-hosted, macOS, umbra-gui]`; the steps stay the same. Because the job
  edits `/etc/hosts` and `PATH`, use a machine that is not used for other work.
