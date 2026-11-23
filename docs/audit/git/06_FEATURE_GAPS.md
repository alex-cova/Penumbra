# 06 — Functional coverage and competitive gaps

Date: 2026-11-22, commit `afc43b7f`.

Classification:
- **Verified**: implemented, and exercised against real git by a test that ran green in this audit or by a probe.
- **Defective**: implemented, but a probe or test showed wrong behaviour.
- **Partial**: some of the capability exists.
- **Missing**: not found after a repository-wide search (`grep` across `Packages/GitIntelligence`, `Umbra/Sources`).
- **N/A**.

A class or method existing is not enough for "Verified".

| Capability | Priority | Status | Implementation and evidence | Quality notes |
|---|---|---|---|---|
| Repository discovery | Critical | **Defective** | `GitRepository.discoverOutcome`; [probe-lib] 3 | Standard, nested, worktree and nested-repo cases are correct. Symlinked project root broken (G-07). Bare repo and `.git` give an error, not "unavailable" (G-15). |
| File status | Critical | **Defective** | `GitStatusParser`, `IDEGitStatusModel.parse`; [probe-lib] 1–2, [probe-app] 1 | The parser is right for every XY tested, conflicts included. The model shows untracked files as staged (G-02). A leading combining mark is dropped (G-16). |
| Staging and unstaging | Critical | **Defective** | `stage`, `unstage`, `stageAll`, `unstageAll`; [probe-lib] 4–5, [probe-app] 5–6 | Fine with commits. Fails before the first commit (G-09). Rename unstage is half-done (G-10). |
| Diff viewer | Critical | **Defective** | `Umbra/Sources/Umbra/Diff/`; `IDEDiffComputerTests`, `IDEDiffTabTests` [test], [probe-app] 2 | Baselines are correct. Saving a non-UTF-8 file corrupts it (G-05). |
| Gutter decorations | High | **Defective** | `IDEChangeMarkers.swift`; `IDEChangeMarkerTests` [test], [probe-app] 9 | Stale after a same-branch commit (G-03). No hit target or inline peek. |
| Commit workflow | High | **Verified** (with caveat) | `IDEGitStatus+Commit.swift`; `IDEGitCommitFlowTests`, `GitCommitChecksIntegrationTests` [test] | Checks, amend, sign-off, skip hooks, template. The commit button is enabled for untracked-only changes (G-02). |
| Branch checkout | High | **Verified** | `switchBranch`, `checkoutRemoteBranch`, `preservingLocalChanges`; `GitRemoteIntegrationTests`, `testSwitchBranchFollowsFileContentsAndRefusesOverwrite` [test] | Smart and force checkout, save-before. |
| Conflict visualization | High | **Verified** | Conflicts section, banner, merge tool; `GitOperationsIntegrationTests`, `IDEMergeComputerTests`, `IDEGitStatusOperationsTests` [test], [probe-lib] 2 | All unmerged pairs are recognised. diff3 is checked against `git merge-file`. |
| Partial staging | High | **Defective / Partial** | Hunk stage and unstage in the diff viewer; [probe-app] 3–4 | Hunks only, no lines. Fails on paths with a space or tab (G-08). Corrupts index EOL under autocrlf (G-04). Blob-id race (G-11). Not available from the gutter. |
| Git history | Medium | **Verified** | `log`, graph layout, filters, Load More; `GitGraphLayoutTests`, `IDEGitStatusModelHistoryTests` [test] | |
| File history | Medium | **Verified** | `log --follow`; `testLogOfAFileFollowsARename` [test] | Line history (`log -L`) too: `GitHistoryIntegrationTests` |
| Blame | Medium | **Verified** | `blame --porcelain --contents -`; `testCommitLogAndBlameWithUnsavedContents`, `IDEBlamePresentationTests` [test] | Uses the live buffer, so unsaved lines show as uncommitted. |
| Branch create and delete | Medium | **Verified** | `+Branches`; `GitRemoteIntegrationTests` [test] | Rename, delete merged, remote delete, tags |
| Stash | Medium | **Verified** | `+Stash`; `GitStashIntegrationTests`, `IDEGitStatusStashTests` [test] | Resolved by hash. Untracked files. Branch from stash. |
| Cherry-pick | Medium | **Verified** | `cherryPick`; `GitHistoryIntegrationTests`, `IDEGitStatusHistoryActionsTests` [test] | Refuses merge commits |
| Rebase | Medium | **Verified** | `rebase(onto:)`, interactive plans; `GitRebasePlanTests`, `GitHistoryIntegrationTests` [test] | Editor-free interactive rebase with re-validation. Not from the root commit. |
| Worktree management | Medium | **Partial** | `GitRepository+Worktree.swift` (list, add, remove); used by the agent's `IDEAgentWorktreeStore`; `GitWorktreeTests`, `IDEAgentWorktreeStoreTests` [test] | No user-facing worktree UI. Opening a linked worktree as a project works ([probe-lib] 3). |
| Fetch, pull, push | Medium | **Verified** | `+Remotes`; `GitRemoteIntegrationTests` (local bare remote) [test] | Progress, force-with-lease, protected branches. No timeout or Cancel, and it blocks local mutations (G-19). |
| Authentication | Medium | **Verified** (local) | Askpass server and client; `IDEGitAskPassTests` [test] | Tested over the socket. Not tested against a real HTTPS or SSH host in this audit. |
| Submodule management | Medium | **Missing** | Only `clone --recurse-submodules` (`GitRepository+Clone.swift`) and the watcher's external git directory | No init, update or sync UI. A modified submodule appears as an `M` row; opening its diff fails (gitlink, [code]). |

## Competitive position

Only capabilities documented by those products and generally known are compared. They were not re-tested here.

| Area | Umbra | VS Code (built-in Git) | IntelliJ IDEA | Zed | Xcode |
|---|---|---|---|---|---|
| Staged/unstaged split | Yes (untracked bug) | Yes | Yes (staging area optional) | Yes | Yes |
| Hunk staging | Diff viewer only | Diff editor, plus line/range staging | Gutter and diff, plus lines | Gutter and panel | Diff, per change |
| Line-level staging | No | Yes (selected ranges) | Yes | — | — |
| Gutter peek and stage | No | Yes | Yes | Yes | — |
| 3-way merge tool | Yes | Yes (merge editor) | Yes | Basic | Yes |
| Interactive rebase UI | Yes (sheet) | No (extension) | Yes | No | No |
| Stash UI | Yes | Yes | Yes | Limited | Yes |
| Line history (`log -L`) | Yes | Timeline (file) | Yes | No | No |
| Commit checks | Yes (conflicts, author, CRLF, size, markers) | Minimal | Yes (inspections) | No | No |
| Worktrees | Agent only | Yes (recent versions) | Yes | — | — |
| Workspace trust before git | **No** | Yes (restricted mode disables git) | Trusted-project prompt | — | — |

**Ahead**: interactive rebase without an editor, commit checks, line history, merge tool fidelity checked against `git merge-file`, smart checkout, a stash keyed by hash, the git console.
**Comparable**: history, blame, branches, remotes, conflicts.
**Behind**: line-level and gutter staging, inline change peek, workspace trust (security), submodules, worktree UI.

## Recommendations (value per effort)

1. Fix the defective Critical and High rows first (G-02, G-03, G-04, G-05, G-07, G-08). They undermine trust in what already exists.
2. Gutter hit target: peek, stage and rollback the hunk under the pointer. Reuse `IDEDiffPatchBuilder` once G-04 and G-08 are fixed. This is the largest everyday-workflow gap against VS Code and Zed.
3. A git trust gate (see `08_SECURITY.md`). It closes a security gap the competitors have addressed.
4. Line-level staging in the diff viewer (select lines → stage). The patch builder already works per line range.
5. Worktree UI only if users ask for it. The library and the agent already cover it.
6. Submodule init and update: low priority for a Sublime-class editor. Showing a submodule row's diff as "Submodule commit a → b" instead of a failure is a cheap improvement.
