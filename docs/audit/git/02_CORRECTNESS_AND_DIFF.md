# 02 — Git correctness and diff engine

Date: 2026-11-22, commit `afc43b7f`, Apple Git 2.54.0. Git CLI is the reference. Evidence labels:

- **[probe-lib]**: `GitIntelligence` linked by path into a scratch package, run against throwaway repositories (`07_TEST_COVERAGE.md` § Probes).
- **[probe-app]**: an XCTest added to a *scratch clone* of this repository that drives the real `Umbra` types. Nothing was added to this checkout.
- **[cli]**: plain git commands in a scratch repository.
- **[code]**: code reading only, not executed.
- **[test]**: an existing test that ran green in this audit.

## 1. Repository discovery

`GitRepository.discoverOutcome` runs `rev-parse --show-toplevel --absolute-git-dir` and standardizes both paths. `IDEGitSupport.repository(for:existing:)` reuses the existing repository when the root is under it.

| Case | Result | Evidence |
|---|---|---|
| Standard repository, root | Correct root and `.git` | [probe-lib] 3 |
| Nested directory | Resolves to the enclosing top level | [probe-lib] 3 |
| Nested repository (`sub/inner` with its own `.git`) | The inner repository wins, as git does | [probe-lib] 3 |
| Linked worktree | Root is the worktree; `gitDirectory` is `.git/worktrees/<name>` | [probe-lib] 3, `GitRepositoryStateTests` [test] |
| Detached HEAD | `GitRepositoryState.Head.detached(sha)` | `GitRepositoryStateTests` [test] |
| Non-git directory | `.notARepository` → model `.unavailable` | [probe-lib] 3, `IDEGitRefreshTests.testAMissingRepositoryStaysUnavailable` [test] |
| Bare repository | **Throws** `fatal: this operation must be run in a work tree`. The model shows a failed refresh with that text instead of "not a repository". | [probe-lib] 3 → G-15 |
| Opening the `.git` directory itself | Same as bare | [probe-lib] 3 → G-15 |
| **Project opened through a symlink** | `repositoryRoot` is the resolved path. Every lookup by the opened path fails: `status(for:)` is nil and `repositoryRelativePath` is nil. | [probe-app] 7 → **G-07** |
| Submodule directory opened as the project | The submodule is its own work tree (git's answer), and its `.git` file points into the superproject. The watcher follows an external git directory (`setGitDirectory`). | [code]; not probed |
| Relocation, deletion, re-init while open | A deleted repository: the next status fails, then discovery returns not-a-repo → `.unavailable` (`applyUnavailable`). Re-init: discovery runs again only when `existing` no longer covers the root, so a re-init in place keeps the old `GitRepository` value. That is harmless because the value is only a path. | [code] |
| Multiple windows, different repositories | One `IDEGitStatusModel` per window, and the lane is keyed per git directory | [code], `GitMutationLaneTests` [test] |

An unrelated repository cannot be attached to a workspace: discovery always runs from the project root, and a parent repository above the project is used on purpose (the project is a folder inside it).

## 2. File status

Library parser (`GitStatusParser`, porcelain v1 `-z`) against git's porcelain v2 output in the same repository [probe-lib] 1–2:

| State | Library entry | Umbra row(s) | Verdict |
|---|---|---|---|
| Unmodified | none | none | ✔ |
| Modified, unstaged (`.M`) | `" M"` | Unstaged | ✔ |
| Staged (`M.`) | `"M "` | Staged | ✔ |
| Partially staged (`MM`) | `"MM"` | Staged **and** Unstaged, as two independent rows | ✔ [probe-lib], `IDEGitRenameAndSelectionTests.testSelectionKeepsBothSectionsAndFollowsAStagedFile` [test] |
| **Untracked (`??`)** | `"??"`, `isUntracked` | **Staged (as "modified") and Unstaged (untracked)** | ✘ **G-02** [probe-app] 1 |
| Added (`A.`) | `"A "` | Staged, "Added" | ✔ |
| Intent-to-add (`.A`) | `" A"` | Unstaged, `.added` | ✔ |
| Deleted staged (`D.`) / unstaged (`.D`) | ✔ | "Deleted" in the right section | ✔ [test] |
| Renamed staged (`R.`) | path = new, `originalPath` = old | One staged row "old → new" | ✔ parsing. Actions: see §3 |
| Copied (`C.`) | Parsed the same way as R | "Copied" | ✔ parsing [test]. `git status` reports copies only with `status.renames=copies`. |
| Ignored | `!!`, collapsed directories | Explorer only (dimmed) | ✔ |
| Conflicted (`UU`, `AA`, `DD`, `AU`, `UA`, `DU`, `UD`) | `isConflicted` true for all | Conflicts section only | ✔ [probe-lib] 2 (AA, UU, UD, DU) |
| Type change (`.T`, file → symlink) | `" T"` | Unstaged, "modified" tint | ✔ (the letter comes from the raw code) |
| Mode change (`chmod +x`) | `" M"` | Unstaged | ✔ (git reports M) |
| Submodule modified | `" M"`, collapsed as a file | Unstaged | Parsing ✔ [code]. Opening its diff reads `cat-file blob` of a gitlink, which fails and shows "failed". Not probed. |

### Names

| Name | Result |
|---|---|
| Spaces, tabs, newlines, quotes, backslash, `-dash`, `*`, `:(glob)*`, NFC accents | Parsed exactly (`-z`, `core.quotepath=off`) and staged literally [probe-lib] 1, 7 |
| **A name that starts with a combining mark** (`"́leading-combining.txt"`) | The mark is **dropped** (`"leading-combining.txt"`). `GitStatusParser` slices the record by `Character`, and the space that separates XY from the path joins the mark into one grapheme. | ✘ G-16 [probe-lib] 1 |
| Non-UTF-8 bytes in a name | `String(decoding:as:UTF8)` would substitute U+FFFD. APFS stores names as UTF-8, so this is limited to other volumes. Not probed. |
| Case-only rename on a case-insensitive volume | Git reports `R` only when staged with `git mv`. Not probed. |

**Critical invariant: staged and unstaged are kept independently.** Held for every tracked file (`IDEGitChange.staged` and `.unstaged` come from the two porcelain columns separately). Broken for untracked files, which gain a fake staged side (G-02).

## 3. Index operations

| Operation | Command | Verdict | Evidence |
|---|---|---|---|
| Stage file(s) | `--literal-pathspecs add -- <paths>` (chunks of 200) | ✔ | [probe-lib] 7, `testPathsWithSpacesNonASCIIAndGlobCharactersAreLiteral`, `testLiteralPathspecsTouchOnlyTheNamedFiles` [test] |
| Stage deleted file | `add -- path` stages the deletion | ✔ (git semantics; no dedicated test) | [code] |
| Unstage file(s) | `--literal-pathspecs restore --staged -- <paths>` | ✔ with commits. **✘ before the first commit**: `fatal: could not resolve 'HEAD'` | G-09 [probe-lib] 4, [probe-app] 6 |
| Stage all | `add -A` | ✔ | [code] (no dedicated test) |
| Unstage all | `restore --staged .` | **✘ before the first commit** (same error) | G-09 [probe-lib] 4 |
| Unstage a staged rename row | `restore --staged -- new` only | **✘ leaves `D  old.txt` staged and `new.txt` untracked** | G-10 [probe-app] 5 |
| Stage hunk / unstage hunk | `apply --cached --unidiff-zero [--reverse] -`, after a check that `:path`'s blob id still matches | ✔ for simple LF UTF-8 files [test]. **✘ for paths with a space or tab** (G-08). **✘ index EOL corruption** under `core.autocrlf`/`eol` attributes (G-04). **Race**: the blob id is read after the texts (G-11). | [probe-app] 3, 4; [probe-lib] 6; [cli] |
| Stage selected lines | Not implemented (whole hunks only) | — | [code] |
| Discard (Changes list, "Discard…") | `restore --source=HEAD --staged --worktree` per path in `HEAD`; added and untracked files are skipped | Behaves as its confirmation text says: "discards every change … **staged or not**". From an unstaged row of a partly staged file it also throws away the staged half. That is IntelliJ-style rollback, unlike VS Code. | [code], `IDEGitChangePresentation.swift:363` → G-17 (UX) |
| Discard a staged rename | `new` is not in `HEAD` → skipped; "nothing to revert to" | ✘ cannot discard a rename from the list | G-10 [probe-lib] 5 |
| Restore a deleted file | Discard on a `.D` row → `restore --source=HEAD` | ✔ | `testRevertBringsBackADeletedFile` [test] |
| Conflict stage resolution | `checkout --ours/--theirs` + `add`, or `rm` when that side deleted the file | ✔ `GitOperationsIntegrationTests` [test] |

Destructive scope: `revertToHead` takes literal paths, so it cannot reach outside the paths requested. Untracked files are never deleted by Discard; they are skipped. No `git clean` exists anywhere (`grep`). ✔

## 4. Diff pipeline

```
git cat-file blob <rev>:<path> ─┐                           ┌─ IDEDiffText (lines split on \n, \r\n, \r)
disk bytes (FileManager) ───────┼─ String(decoding:UTF8) ───┤
open dirty editor buffer ───────┘                           └─ IDEDiffComputer.chunks (LCS, whitespace policy)
                                                               ├─ viewer bands and ribbons
                                                               ├─ IDEDiffPatchBuilder → git apply --cached
                                                               └─ change markers (buffer ↔ HEAD only)
```

Umbra does **not** parse `git diff`. It reads both sides and diffs them itself. So "matches git" means the same sides and comparable line splitting.

### Baselines

| View | Left | Right | Correct? |
|---|---|---|---|
| Staged row → diff | `HEAD:<old or same path>` | `:<path>` (index) | ✔ (renames use the porcelain old path; `IDEGitRenameAndSelectionTests` [test]) |
| Unstaged row → diff | `:<path>` (index) | working tree. The open editor's buffer **if it is dirty**, read-only then. | ✔ baseline. The right side is raw bytes, with no clean or EOL filter (§5). |
| Untracked → diff | empty | working tree | ✔ |
| Gutter markers | `HEAD` blob (cached) | live buffer | Baseline ✔ (IntelliJ-style: staged edits stay marked until committed). **Cache goes stale after a same-branch commit** (G-03). |
| Show Diff with HEAD | `HEAD` | working tree | ✔ [code] |
| Commit file | `<hash>^` | `<hash>` | ✔ [test] `IDEGitStatusModelHistoryTests` |

### Required cases

| Case | Verdict | Evidence |
|---|---|---|
| Inserted, deleted, modified, multiple and adjacent hunks | ✔ chunks applied back with real git reproduce the target | `IDEDiffPatchBuilderTests.testPatchesApplyWithGit` [test] |
| Empty file; no trailing newline | ✔ `\ No newline at end of file` handled | [test] |
| CRLF vs LF (no conversion configured) | ✔ CRLF kept in patches | `testCRLFLinesKeepTheirLineBreaks` [test] |
| **CRLF working tree with `core.autocrlf=true` (index LF)** | Viewer: the line endings are invisible (terminators are excluded from comparison), so only the real edit shows. **Hunk staging writes the CRLF line into the LF index → `i/mixed`.** | **G-04** [probe-app] 4, [cli] |
| Mixed line endings | Lines split on `\r` too. Git does not treat a lone CR as a line end, so hunk line numbers drift for files with bare CR. | G-21 [code], not probed |
| Unicode, multibyte (UTF-8) | ✔ UTF-16 ranges throughout | [test] |
| **Non-UTF-8 text (Latin-1, Windows-1252)** | Both sides are decoded with U+FFFD substitution. **Saving the editable side rewrites the whole file as UTF-8 with U+FFFD** (`E9` → `EF BF BD`). Gutter: every non-ASCII line looks modified. | **G-05** [probe-app] 2; G-18 [code] |
| Large files | The diff runs off the main thread. The gutter collapses a differing middle over 20,000 lines to one span. | [test] |
| Binary | A NUL in the first 8 KB → "binary", no hunks | [code], [test] |
| Renamed, copied | Hunk staging refused ("stage the whole file") | `testARenameComparisonDoesNotApplyAHunk` [test] |
| Partially staged | Two rows. Each opens its own baseline pair. | [test] |
| Whitespace-only | `IDEDiffWhitespacePolicy` (none, trim, ignore, ignore + empty lines) | [test] |
| Unsaved editor buffers | The diff shows the buffer. Hunk staging refuses ("Save the file before staging hunks"). | `IDEDiffHunkSafetyTests` [test] |

### Gutter decorations

| Property | Verdict |
|---|---|
| Matches added, modified and deleted regions | ✔ `IDEChangeMarkerTests` [test] |
| Updates after editing | ✔ Spans shift immediately, then the diff runs 400 ms after the pause, off main, dropped if the buffer's `contentGeneration` moved [code] |
| Updates after stage or unstage | Not applicable: the baseline is HEAD, so staging does not change the marks (intended) |
| **Updates after commit / amend / reset / fast-forward pull** | **✘** `headMoved` is false when the branch name did not change, so the cached pre-commit blob stays (G-03, [probe-app] 9) |
| After discard | ✔ The buffer reloads, `contentGeneration` changes, and it re-diffs [code] |
| Line coordinates | Line-based spans are recomputed per diff and moved by the engine between diffs (`setGutterChanges`); wrapping and folding are drawn by Penumbra's gutter. Not exercised visually in this audit. |
| Per-keystroke cost | One debounced task per editor. No git process per keystroke (the HEAD blob is cached). The diff is O(file) after each pause and after **every** git refresh (`refreshChangedLinesInOpenEditors(force: true)`), limited to the visible pane per pane. [code] |

## 5. Root causes, in brief

- **G-02**: `statusFromIndexChar` returns `.modified` for any character it does not list, including `?` (`IDEGitStatus.swift:1269–1277`).
- **G-03**: `headChanged = state.head != repositoryState.head` compares `.branch("main")` with `.branch("main")` (`IDEGitStatus.swift:386`).
- **G-04 / G-05**: the working-tree side is `FileManager.contents` → `String(decoding:as:UTF8)` (`IDEGitStatus.swift:885–893`, `:946–949`). `IDEDiffSession.save` writes `.utf8` and treats an undecodable disk file as "no conflict, nothing to lose" (`IDEDiffSession.swift:318–325`). Patches carry those bytes into `git apply --cached`, which applies no conversion.
- **G-08**: `IDEDiffPatchBuilder` writes `a/"my file.txt"`. Git's c-quoting is `"a/my file.txt"`, and git apply rejects the former ([cli]: `error: "my file.txt": does not exist in index`). The existing test only checks the string, never applies it.
- **G-09**: `git restore --staged` needs `HEAD`. Before the first commit, `git rm --cached -- <paths>` is the equivalent.
- **G-10**: `unstage(paths:)` sends only `relativePath`, not `originalPath`. `revert` checks only the new path against `HEAD`.
- **G-11**: `IDEDiffSession.reload` awaits `indexBlobID` *after* both texts loaded (`IDEDiffSession.swift:199–203`). With zero context, a pure insertion is applied at its line number without checking any content ([probe-lib] 6: `X` landed between `a` and `b` of a changed index, no error).
