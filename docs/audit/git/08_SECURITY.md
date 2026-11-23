# 08 — Security and data integrity

Date: 2026-11-22, commit `afc43b7f`. No hooks or unsafe operations were run against real repositories. The command-execution demonstration (§2) used a throwaway repository in the scratchpad. Its "payloads" only created marker files there.

## 1. Execution boundary

| Check | Result | Evidence |
|---|---|---|
| No shell concatenation | ✔ Every call is `posix_spawn("/usr/bin/git", [args])`. The one shell git itself runs is `GIT_SEQUENCE_EDITOR='cp <todo>'`, whose path is `GitRebasePlan.shellQuoted` and points under the git directory. | `SubprocessRunner`, `GitRepository+History.swift` [code] |
| User paths cannot inject options | ✔ Paths follow `--`. Branch, remote, tag, revision and range names starting with `-` are refused (`validatedBranchName`, explicit guards). Clone uses `--` before the address. | [code], `testCreateBranchRejectsALeadingDash` [test] |
| Pathspec magic | ✔ `--literal-pathspecs` on path commands | [probe-lib] 7 |
| Remote helpers | ✔ Apple git defaults (`protocol.ext.allow=never`; `file` is user-only for submodules) are not overridden | [code] |
| Diagnostics kept | ✔ `GitError.failed` carries the exit status, stderr and stdout. The console keeps the last 500 failed or mutating commands with stderr and 4 KB of output. | [code] |
| Credentials in logs | ✔ No `os_log`, `print` or `NSLog` in the git code (`grep`). The console store is in memory only and per process. A clone address that embeds a token (`https://tok@host/…`) is kept in that in-memory store as an argument and shown in the console. P3: redact `user:pass@` in `GitCommandRecord.arguments` before display. | [code] |
| Askpass | ✔ Unix socket in a 0700 directory, a per-launch token and a session id. Prompts go only to the owning window. Nothing is stored by Umbra. | `IDEGitAskPassTests` [test] |
| Destructive scope | ✔ Discard: literal paths, `restore --source=HEAD`, never deletes untracked files, no `git clean`. Reset, force checkout and drop are confirmed. | [code], [test] |
| Writes outside the repository | ✔ `resolve(path:with:)` and the diff save write `root + path` from git or a request path; no `..` was found in any git-supplied path. P3: `resolve(path:with:)` writes atomically, which replaces a symlink at that path with a regular file rather than writing through it. | [code] |

## 2. G-01 (P0): repository-local configuration runs commands on open

**Threat model.** A folder whose `.git/config` was written by someone else: a downloaded or extracted archive that includes `.git`, a shared or network volume, a USB stick, a repository a colleague zipped up. `git clone` does **not** carry `.git/config`, so a plain clone is not this vector. Git's `safe.directory` check does not help when the current user owns the files (the usual case after extracting an archive).

**What happens.** Opening the folder triggers `setRoot` → `refresh()` → `git status`, with no user action. Git honours repository-local settings that name programs:

| Setting | Runs on | Umbra trigger | Demonstrated |
|---|---|---|---|
| `core.fsmonitor = <command>` | `status`, `ls-files`, `diff`, `add`… | Every refresh, every save, app activation, Find in Files (`ls-files`) | ✔ marker created by Umbra's exact `status` and `ls-files` arguments |
| `diff.external = <program>` | `git diff` without `--no-ext-diff` | `unstagedDiff`, `stagedDiff`, `workingTreeDiff`, `commitDiff`, `show` | ✔ marker created by Umbra's `diff -- path` arguments |
| `diff.<driver>.textconv` + `.git/info/attributes` | `diff`, `log -p`, `show`, `blame` | as above | Configured. The marker appeared only for the fsmonitor and extdiff paths in this run; not separated. |
| `core.hooksPath`, `.git/hooks/*` | commit, checkout, merge, rebase, push | **User-initiated** actions only | Expected git behaviour. Skip Hooks is available for commit. |
| `filter.<driver>.clean/smudge` | `add`, checkout, sometimes `status` | stage (user-initiated), possibly refresh | Not tested |
| `core.sshCommand`, `credential.helper` | fetch, pull, push | User-initiated, or background fetch (off by default) | Not tested |

Evidence ([cli], `scratchpad/probe/untrusted`):
```
git config core.fsmonitor "touch <marker>.fsmonitor; false #"
git --no-optional-locks -c core.quotepath=off status --porcelain=v1 -z --untracked-files=normal   → <marker>.fsmonitor created
git --no-optional-locks -c core.quotepath=off --literal-pathspecs diff -- a.txt                   → <marker>.extdiff created
git --no-optional-locks -c core.quotepath=off --literal-pathspecs ls-files -z --cached --others … → <marker>.fsmonitor created
```

**Impact.** Arbitrary command execution as the user when a folder is opened. Under the App Sandbox that execution is limited to the sandbox's reach. `Umbra/Resources/Umbra.entitlements` has no `com.apple.security.app-sandbox` key (checked), so the reach is the user's account.

**Comparison.** VS Code disables its git extension in Restricted Mode until the folder is trusted. Umbra already has trust prompts for Gradle, Maven, npm and language servers (`IDESharedServices`, `IDELanguageServerTrust.swift`), but not for git.

**Fix (choose one, or layer them).**
1. Run every *automatic* read with `-c core.fsmonitor=false` and the diff family with `--no-ext-diff --no-textconv`. That is cheap and closes the demonstrated vectors. It does not cover `filter.*` on `status` (rare) or hooks (user-initiated).
2. A git trust gate per repository, reusing the existing trust store pattern. Until the folder is trusted, run only `rev-parse` and read `HEAD` and config *files* directly, and show "Trust this repository to enable Git" in the Changes tab.
3. Optionally, on first trust, warn when `.git/config` contains `fsmonitor`, `sshCommand`, `hooksPath`, `pager`, `editor`, `external` or `textconv` keys.

Regression test: `setRoot` on a repository whose `core.fsmonitor` writes a marker; assert no marker until it is trusted.

## 3. Data-integrity risks

| ID | Risk | Severity | Status |
|---|---|---|---|
| G-05 | Diff-viewer save turns every non-UTF-8 byte of the file into U+FFFD, silently (the "changed on disk" check is skipped when the disk does not decode as UTF-8) | **P0** | Confirmed [probe-app] A2 |
| G-04 | Hunk staging writes working-tree line endings into the index under `core.autocrlf` or `eol` attributes (`i/mixed`); the next commit carries them | **P1** | Confirmed [probe-app] A4 |
| G-11 | Zero-context insertion applied at a stale line number if the index changes between loading the texts and reading the blob id | P2 | git behaviour confirmed [probe-lib] L6; race window from code reading |
| G-14 | Closing a window kills a running commit, pull or rebase step | P2 | [code] |
| G-17 | Discard on an unstaged row also discards the staged version (confirmed by the dialog text) | P3 (UX) | [code] |
| — | Git operations overwriting unsaved buffers | ✔ Switch, pull, merge, rebase, stash apply, reset, cherry-pick and rewrite save first (`afterSaving`). Discard warns and reloads. | [code] |
| — | Hunk staging of unsaved text | ✔ refused | `IDEDiffHunkSafetyTests` [test] |

## 4. Summary

The process boundary is solid: no shell, literal pathspecs, option refusal, scoped destructive actions, careful askpass. The open gap is trust: Umbra runs git on any folder it opens and lets that repository's own configuration name programs. Two data-integrity defects (G-05, G-04) come from the diff viewer treating the working tree as raw UTF-8 bytes.
