# SubprocessKit plan

A small, **zero-dependency** path package at `Packages/SubprocessKit/`, modeled after `GitIntelligence` and `AgentKit`. It owns all `posix_spawn` + pipe I/O. Callers keep their existing protocols (`ProcessRunning`, `GitRunning`, `GradleProcessLaunching`); only the default system implementations switch to SubprocessKit.

## Motivation

- **Four hand-written spawn paths today**, with different bugs: `SystemProcessRunner` (`Foundation.Process`, reads stdout to EOF and *then* stderr, so a child that writes more than 64 KB to stderr deadlocks), `SystemGitRunner` (`Process` + `DispatchGroup`), `SystemGradleProcessLauncher` (`Process` + readability handlers + a lock-based `TerminationCoordinator`), and `AgentProcess` / `CheckRunner` (two copies of the same `posix_spawn` block).
- **`Task policy set failed`** appears in the system log while Umbra runs children. We do not yet know whether `Process` is the cause, so this is a hypothesis, not a goal: Phase 0 captures a baseline and Phase 6 compares. Removing the duplication and the sync-path deadlock is worth doing either way.

## Status

Phases 0–5 are implemented: the package, `SystemProcessRunner`, `SystemGitRunner`, `SystemGradleProcessLauncher` (and with it javac diagnostics), `AgentCommandRunner` and `CheckRunner` all run through SubprocessKit, and `AgentProcess`, `TerminationCoordinator` and the duplicated `posix_spawn` blocks are gone. `swift test --package-path Packages/SubprocessKit` (44 tests, also under `--sanitize=thread`) and the regression suites listed under *Testing strategy* pass (123 XCTest tests plus 21 AgentEval tests). The new `JDKLocatorTests` stderr test was checked against the old runner: it deadlocks there.

**Not done: the `Task policy set failed` baseline (Phase 0) and comparison (Phase 6).** Both need the app running with a window and the four scenarios driven by hand, so neither number exists yet. Until they do, the warning is still a hypothesis and the migration is justified by the deduplication and the fixes below, not by it.

Found while implementing, now in the code and the rules below: children inherited an ignored `SIGTERM` from the host, so every timeout waited out its grace period for SIGKILL (the old `AgentProcess` too); a result no longer waits for EOF when a grandchild holds the pipe open.

**Out of scope:** the SwiftTerm PTY terminal, `JavaDebugProcessLauncher` (bidirectional stdin), `Tools/PerfHarness/Sources/MetalCommands.swift` (`Process()` in a dev tool), test-only `Process()` helpers.

**App Store:** SubprocessKit is a host-layer package. `Penumbra` and `EditorIntelligence` never link it, so the "no `Process` inside the library targets" rule in the root `CLAUDE.md` still holds. Children inherit the app's sandbox and the same user-consent gates as today.

**Alternative considered:** swiftlang/swift-subprocess. Rejected for now to keep `GitIntelligence` free of third-party dependencies and to control spawn attributes exactly (`CLOEXEC_DEFAULT`, `SETPGROUP`). Revisit if it supports macOS 14 and exposes those.

---

## Goals

| Goal | How |
|------|-----|
| One spawn implementation | `SubprocessKit` only |
| No `Foundation.Process` on migrated paths | `posix_spawn` + `pipe` + non-blocking reads |
| No blocked Swift-concurrency threads | Blocking work never runs on the cooperative pool (see Rules) |
| Kill trees where it is safe | Opt-in process group (agent, AgentEval); Gradle keeps leader-only kill |
| Streaming + bounded capture | Per-stream capture policy; separate or merged streams |
| Testable | Protocols unchanged; fakes stay in tests |

**Success metric:** existing suites green (list under *Testing strategy*), the new SubprocessKit suite green under TSan, and the Phase 0 / Phase 6 `Task policy` comparison recorded (informational, not a gate).

---

## Package layout

```
Packages/SubprocessKit/
  Package.swift          # tools 6.0, macOS 14+, Swift 6 mode, no deps (same as GitIntelligence)
  CLAUDE.md              # short usage note for agents
  Sources/SubprocessKit/
    SubprocessRequest.swift
    SubprocessResult.swift
    SubprocessError.swift
    Subprocess.swift           # posix_spawn with the request's descriptors and attributes
    PipeIO.swift               # PipeReader / PipeWriter: non-blocking fds on dispatch sources
    OutputCapture.swift        # .all / .bounded(head:tail:) / .discard, CapturedOutput (from AgentBoundedOutput)
    UTF8ChunkDecoder.swift     # from AgentUTF8ChunkDecoder
    SubprocessJob.swift        # one running child: readers, timer, reaper thread, signals
    SubprocessRunner.swift     # async run + runBlocking, both over SubprocessJob
  Tests/SubprocessKitTests/
    SpawnTests.swift           # echo, exit code, cwd, closed stdin, env inherit vs custom, launch failure
    PipeTests.swift            # >64 KB on both streams, stdin data, child exits before reading stdin
    TerminationTests.swift     # timeout, cancel, process group, signal, grace period
    OutputCaptureTests.swift   # moved from AgentBoundedOutputTests
    UTF8ChunkDecoderTests.swift  # moved from AgentUTF8ChunkDecoderTests
```

**Wiring.**
- `Packages/GitIntelligence/Package.swift` adds `.package(path: "../SubprocessKit")`. It is no longer "dependency-free": update `Packages/GitIntelligence/CLAUDE.md` and the root `CLAUDE.md` bullet to "depends only on SubprocessKit".
- Root `Package.swift` adds `.package(path: "Packages/SubprocessKit")` and `.product(name: "SubprocessKit", package: "SubprocessKit")` on `JavaIntelligence`, `AgentEvalKit` and `Umbra`. `PenumbraTests` adds it only if a test imports it.

---

## Public API (minimal surface)

### Request

```swift
public struct SubprocessRequest: Sendable {
    public var executable: String              // absolute path
    public var arguments: [String]
    public var workingDirectory: URL?
    public var environment: [String: String]?  // nil = inherit this process's environment (ProcessInfo.processInfo.environment)
    public enum StandardInput: Sendable {
        case closed          // /dev/null (default)
        case data(Data)      // write then close (git apply)
    }
    public var standardInput: StandardInput = .closed
    public enum OutputRouting: Sendable {
        case separateStreams
        case merged          // stderr -> stdout pipe (agent commands)
    }
    public var output: OutputRouting = .separateStreams
    public var stdoutCapture: OutputCapture = .all    // git: .all; agent: .bounded(64K, 192K); CheckRunner: tail 12K
    public var stderrCapture: OutputCapture = .all
    public var processGroup: Bool = false      // POSIX_SPAWN_SETPGROUP; signals go to -pid
    public var killGroupOnExit: Bool = false   // after the leader exits, kill what it left in the group
    public var timeout: Duration?              // nil = no limit
    public var terminationGrace: Duration = .seconds(2)  // SIGTERM, then SIGKILL after this
}
```

### Result

```swift
public struct SubprocessExit: Sendable {
    public var exitCode: Int32?   // nil when killed by a signal
    public var signal: Int32?
    public var succeeded: Bool    // exitCode == 0
    public var status: Int32      // exitCode, else the signal number, else -1
}

public struct SubprocessResult: Sendable {
    public var exit: SubprocessExit
    public var stdout: CapturedOutput   // merged output lands here when output == .merged
    public var stderr: CapturedOutput
    public var timedOut: Bool
    public var cancelled: Bool
    public var duration: TimeInterval
}

/// What a stream kept: `head`, `tail`, `omittedBytes`, and `data` / `text` (the text carries a
/// "[… N bytes omitted …]" marker where the middle was dropped).
public struct CapturedOutput: Sendable, Equatable { … }

public enum SubprocessError: Error, Sendable, Equatable {
    case launchFailed(errno: Int32)   // missing executable, bad cwd, ...
    case pipeFailed(errno: Int32)
}
```

A non-zero exit, a signal, a timeout and a cancellation are **results**, not thrown errors; callers map them (`GitError.failed`, `GradleCommandError.timedOut`, `ProcessRunError.nonZeroExit`). Only failing to start throws.

### Runner

```swift
public enum SubprocessRunner {
    /// The async core: cancellation, timeout, optional live chunks.
    public static func run(
        _ request: SubprocessRequest,
        onOutput: (@Sendable (Data, SubprocessOutputSource) -> Void)? = nil
    ) async throws -> SubprocessResult

    /// Blocking wrapper over the async core for `ProcessRunning`'s sync API.
    /// Never call from the cooperative pool's hot paths; the existing callers (JDK discovery,
    /// `command -v gradle`) are already off the main actor.
    public static func runBlocking(_ request: SubprocessRequest) throws -> SubprocessResult
}

public enum SubprocessOutputSource: Sendable { case stdout, stderr }   // not `Stream`: that clashes with Foundation.Stream
```

Internal: `Subprocess.spawn` (descriptors and attributes) and `SubprocessJob` (readers, timeout timer, the reaper thread, `terminate` and the group kill). `run` and `runBlocking` are two ways of waiting on one job.

**Rules (from existing code and review):**

- Always `POSIX_SPAWN_CLOEXEC_DEFAULT`; only the descriptors set up by file actions survive the exec.
- **Reset signal state in the child** (`SETSIGDEF` for every signal, an empty `SETSIGMASK`). Found while writing `TerminationTests`: the child inherited an ignored `SIGTERM` from the test host, so every timeout waited out the grace period until SIGKILL. `AgentProcess` had the same flaw; its tests only bounded the time loosely.
- Default stdin is `/dev/null` (the Gradle hang fix).
- `posix_spawn_file_actions_addchdir_np` for `workingDirectory`. The non-`_np` name needs the macOS 26 SDK (`AgentProcess` uses it because Umbra targets 26) and this package targets macOS 14, as `CheckRunner` does.
- **Blocking never runs on the cooperative pool.** The pool is about one thread per core; a `Task` parked in `read`/`waitid` can starve it (a few concurrent `git` calls × two readers + a waiter is enough). Pipes are non-blocking fds read with `DispatchSourceRead` on a private serial queue with no explicit QoS; the child is reaped on a dedicated `Thread` (`waitid(WEXITED | WNOWAIT)` first, then `waitpid`), so its pid cannot be reused while a signal might still be sent and a child that exits immediately is not missed. The async API bridges with continuations.
- **Both output pipes are always drained concurrently**, including in `runBlocking` (the same job plus a semaphore, not a sequential read and not a `Task`). This fixes `SystemProcessRunner`'s stdout-then-stderr deadlock.
- **A result does not wait for EOF.** Once the leader is reaped, whatever is in the pipes is taken and the run ends. A grandchild that keeps the write end open (a daemon, a `&` job) cannot hang it; its later output is dropped. (`SystemGitRunner` used to wait for EOF, `SystemGradleProcessLauncher` did not.)
- **Writing stdin cannot kill the app.** Set `F_SETNOSIGPIPE` on the write end; treat `EPIPE` as "the child stopped reading" (not an error), then close.
- Decode wait status by hand (`status & 0x7f`, `(status >> 8) & 0xff`); `WIFEXITED` and friends are not imported (as the old `AgentProcess.waitForExit` did).
- Terminate: SIGTERM to `-pid` (group) or `pid` (leader only), then SIGKILL after `terminationGrace`. The signal is sent under the job's lock and only while the leader has not been reaped, so it cannot hit a recycled pid. The delayed SIGKILL follows the same rule for a lone leader; for a process group it is sent even after the leader is gone, because the group can outlive it (pids are not reused while a group with that id exists).
- `killGroupOnExit` is separate from `processGroup`: right for `/bin/zsh -c` (nothing it starts may outlive it), wrong for a tool that deliberately leaves a daemon.

---

## Migration map

| Current | New | Notes |
|---------|-----|-------|
| `SystemProcessRunner` (`Discovery/JDKLocator.swift`) | `SubprocessRunner.runBlocking` | `ProcessRunning` unchanged; throws `ProcessRunError.executableNotFound` / `.nonZeroExit` as today |
| `SystemGitRunner` | `SubprocessRunner.run` | Keep `-c core.quotepath=off`, the env merged over the inherited environment, the `gitNotFound` check, `GitError.failed` on non-zero; stdin from `.data` |
| `SystemGradleProcessLauncher` | `SubprocessRunner.run` + `onOutput` | Reuse `GradleOutputLineSplitter`; **leader-only kill, 5 s grace** (see Phase 3); drop `TerminationCoordinator` |
| `JavaCompilerDiagnosticsService` | no code change | Its default launcher is `SystemGradleProcessLauncher`, so Phase 3 changes javac diagnostics too |
| `AgentProcess` / `AgentCommandRunner` | Thin Umbra wrapper over `SubprocessRunner` | `processGroup` + `killGroupOnExit`, 2 s grace, merged output, bounded capture; keep `AgentCommandSpec`, `AgentCommandEnvironment`, `AgentCommandResult` |
| `CheckRunner` (AgentEval) | `SubprocessRunner` | `processGroup`, SIGKILL on timeout (grace 0), tail capture 12 K, exit 124 on timeout; delete the duplicated `posix_spawn` block |

**Do not migrate yet:** `JavaDebugProcessLauncher` (interactive pipes), SwiftTerm, test `Process()` for compiling fixtures.

---

## Phased rollout

### Phase 0 — Scaffold + baseline (½ day)

- **Baseline first:** with the current build, run `log stream --predicate 'eventMessage CONTAINS "Task policy"'` while opening a project, running git status, a Gradle sync and an agent `run_command`; save the counts in this doc.
- Add `Packages/SubprocessKit` (product `SubprocessKit`, tools 6.0, macOS 14, Swift 6).
- Move `AgentBoundedOutput` → `OutputCapture` and `AgentUTF8ChunkDecoder` with their tests; implement spawn, readers and termination.
- Tests: `SpawnTests`, `PipeTests`, `TerminationTests`. Run `swift test --package-path Packages/SubprocessKit`, once with `--sanitize=thread`.

### Phase 1 — `SystemProcessRunner` (½ day)

- Replace the body with one `runBlocking` call.
- `JavaIntelligence` depends on `SubprocessKit`.
- Add a regression test: a child that writes >64 KB to stderr then exits non-zero must return, not hang. Done twice: `PipeTests.testTheBlockingRunnerDrainsStderrWhileReadingStdout` in the package and `JDKLocatorTests.testSystemProcessRunnerDoesNotHangWhenAChildFillsStderrAndFails` through `SystemProcessRunner` itself.
- `JDKLocatorTests` and every fake runner unchanged.

### Phase 2 — Git (1 day)

- Replace `SystemGitRunner` only; cancellation through the async core.
- `GitIntelligence` depends on `SubprocessKit` (package manifest, not root); update both `CLAUDE.md` files.
- `PipeTests` covers >64 KB on both streams and `git apply`'s stdin with an early-exiting child. The integration coverage is in `PenumbraTests` (there is no `Tests/` in `Packages/GitIntelligence`): `GitRepositoryIntegrationTests`, `IDEGitVisibleFilesTests`, `IDEGitStatusModelHistoryTests`, `IDEDiffPatchBuilderTests` (real `git apply`), and `SystemGitRunnerTests` (the runner itself: stdin, failure status and stderr, env merge, `core.quotepath`, output past a pipe, cancellation).

### Phase 3 — Gradle (1 day)

- Stream into `GradleOutputLineSplitter`; map `SubprocessResult` → `GradleCommandError.timedOut(partial:)` / `.cancelled(partial:)`; a failed spawn → `.executableNotFound`.
- **Keep today's kill semantics: signal the leader only** (`processGroup: false`), SIGTERM then SIGKILL after 5 s. Today `TerminationCoordinator` signals one pid. With `SETPGROUP` the Gradle client and any daemon it starts could share a group, so a timeout or Stop would kill a shared daemon and the next sync would start cold; and a `run` JVM is the daemon's child, so a group kill would not stop it anyway. Group kill for Gradle is a follow-up, only after confirming the daemon survives.
- Because `JavaCompilerDiagnosticsService` uses the same launcher, re-run `JavaCompilerDiagnosticsServiceTests` here.
- `GradleCommandRunnerTests` (`testSystemLauncherTimesOutAndKillsProcess`, `testSystemLauncherHonorsTaskCancellation`, `testSystemLauncherClosesChildStandardInput`) must still pass; the fakes (`RecordingLauncher`, `FakeJavacLauncher`, `FixtureWritingLauncher`, `NoOpLauncher`, `ScriptedLauncher`) are untouched.

### Phase 4 — Agent (½ day)

- `AgentCommandRunner.run` → `SubprocessRunner` with `merged` output, `processGroup`, `killGroupOnExit`, `.bounded(64K, 192K)`; map to `AgentCommandResult` (`output` text, `omittedBytes`, `timedOut`, `cancelled`).
- Delete `AgentProcess`, `AgentBoundedOutput` and `AgentUTF8ChunkDecoder` from Umbra.
- Keep the behavior tests in `AgentCommandRunnerTests`; move `AgentBoundedOutputTests` and `AgentUTF8ChunkDecoderTests` into SubprocessKitTests.
- The API is unchanged for the other callers: `IDEAgentCommandTools.swift`, `IDEAgentConversation.swift` (`!command`), `IDEAgentCommandToolTests`.

### Phase 5 — AgentEval + cleanup (½ day)

- `CheckRunner` uses SubprocessKit; `Atomic` stays (`Tools.swift` and `TrialRunner.swift` use it).
- Grep for leftover production `Process()` / `posix_spawn` in the migrated areas.
- Add `Packages/SubprocessKit/CLAUDE.md` (when to use it, no Penumbra dependency, the rules above in two lines) and a SubprocessKit bullet to the root `CLAUDE.md` package list.

### Phase 6 — Verify (½ day)

- Repeat the Phase 0 log capture on the new build and record both numbers here. If the warning does not drop, `Process` was not the cause (the terminal still uses SwiftTerm); the cleanup stands on its own.

---

## Testing strategy

**SubprocessKitTests (fast, no Umbra):** stdout/stderr separately and merged; non-zero exit; signal kill; timeout kills the process group (shell spawns `sleep`); leader-only kill leaves a grandchild; cancellation mid-run; stdin closed (prompting program exits); stdin data; child exits before reading stdin (no crash); >64 KB on both streams without deadlock; UTF-8 split across reads; bounded capture reports omitted bytes; nonexistent executable and nonexistent cwd → `SubprocessError.launchFailed`.

**Existing suites (must not regress):**

```bash
swift test --package-path Packages/SubprocessKit
swift test --package-path Packages/SubprocessKit --sanitize=thread
swift test --filter 'AgentCommandRunnerTests|IDEAgentCommandToolTests|GradleCommandRunnerTests|JDKLocatorTests|JavaCompilerDiagnosticsServiceTests|GitRepositoryIntegrationTests|SystemGitRunnerTests|IDEGitVisibleFilesTests|IDEDiffPatchBuilderTests|AgentEvalTests'
```

**Fakes unchanged:** `FakeProcessRunner`, `StubProcessRunner`, `RecordingLauncher`, `FakeJavacLauncher`, `FixtureWritingLauncher`, `NoOpLauncher`, `ScriptedLauncher`; the protocols stay the injection point.

---

## Dependency graph (after)

```
SubprocessKit          (no deps)
    ↑
GitIntelligence
JavaIntelligence
Umbra                  (agent wrapper only)
AgentEvalKit
```

`Penumbra`, `EditorIntelligence` and `AgentKit` do **not** link SubprocessKit.

---

## Risks and mitigations

| Risk | Mitigation |
|------|------------|
| Pipe deadlock (either stream filling while the other is read) | Always drain both concurrently, sync path included; `PipeTests` |
| Blocked cooperative-pool threads | Non-blocking reads on a private queue, `waitid`/`waitpid` on a dedicated `Thread`; never block a `Task` |
| SIGPIPE kills the app when writing stdin | `F_SETNOSIGPIPE`; `EPIPE` ends the write quietly; tested with an early-exiting child |
| Gradle daemon killed by a group kill | Gradle stays leader-only in this plan |
| Orphans after an agent/AgentEval timeout | `processGroup` + `killGroupOnExit` |
| Signal hits a recycled pid | Signals go out under the lock only before the leader is reaped, after `waitid(WNOWAIT)`; the delayed SIGKILL for a group relies on the group id being held while members live |
| Gradle JVM stdin hang | Default `.closed`; `testSystemLauncherClosesChildStandardInput` |
| `Task policy set failed` is not from `Process` | Baseline in Phase 0, comparison in Phase 6; not a gate |
| `posix_spawn` path length / env size | Same limits as today |

---

## What stays in Umbra (not SubprocessKit)

- `AgentCommandSpec`, `AgentCommandEnvironment`, `AgentCommandResult`: agent-specific policy.
- `AgentCommandRunner`: thin adapter that builds the `SubprocessRequest` for `/bin/zsh -c` and maps the result.
- Gradle console UI, git UI: unchanged.

---

## Suggested PRs

**PR 1:** SubprocessKit package + Phases 0–1 (`SystemProcessRunner` only). Smallest diff, proves packaging, the sync path and the baseline.

**PR 2:** Git + Gradle (Phases 2–3). The Gradle launcher also drives javac diagnostics, so review both.

**PR 3:** Agent + AgentEval + cleanup + verify (Phases 4–6).

Each PR should be independently reviewable and green in CI.
