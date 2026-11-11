# Umbra Git interaction spec

Date: 2026-11-11. The behavior phase 1–4 of `GIT_FRONTEND_IMPLEMENTATION_PLAN.md` should reach. Where the current app already behaves this way, the spec says “today”. Where it does not, the spec is the target and names the finding.

The model stays `@MainActor` and `@Observable`. Views call it. They do not start `git`.

## States the chrome reads

`GitRefreshState` is the status of the last snapshot attempt. `actionStatus` / `actionFailed` is the last mutation. They stay separate. A failed push must not look like a lost repository.

| State | Chrome | List | Commit field | Caption |
|---|---|---|---|---|
| `.unavailable` | Hidden. Git menu disabled | — | — | — |
| `.loading(nil)` | Changes tab visible | Empty | Hidden | “Updating status…” |
| `.loading(last)` or `.stale` | Visible | Last rows | Enabled as today | “Updating status…” |
| `.idle` | Visible | Rows, or “No changes” | Enabled as today | None |
| `.failed(nil, message)` | Visible | No rows | Hidden | `message`, plus Refresh |
| `.failed(last, message)` | Visible | Last rows | Enabled as today | `message` in `ColorToken.error` |

`isBusy` disables Commit, the overflow menu, and the sync buttons. It does not clear the list. The caption names the operation (“Staging…”, “Committing…”, “Switching branch…”) until `actionStatus` is replaced by the result.

`isNetworkBusy` shows the existing progress row. A local command does not cancel it. The progress row and the status caption can both be visible. Stack them. Do not merge the strings.

## Open Changes

Today: View ▸ Toggle Changes, ⌃⌘G (⌘K and ⌘9 on the IntelliJ map), the sidebar icon, and Git ▸ Show Source Control. `showSourceControl` calls `showSidebarTab(.changes)`. `ideSidebarFocus` focuses the commit field when a shortcut raised a focus request. A click on the icon does not move focus out of the editor.

Target, unchanged for the click path. The command Git: Focus Commit Message always raises the focus request, including when the tab is already visible, and then focuses the field.

Escape in the field calls `focusActiveEditor` (today). Escape in the list focuses the field (today).

## Selection

The model owns one selection. A row is the repository root, the section, and the path. A path in Staged and Changes is two rows and one path.

- Click selects that row. ⌘-click toggles that row and leaves the other section of the same path alone. ⇧-click extends inside the section that row belongs to. The anchor has to be in that section; otherwise the click selects the row that was clicked.
- Arrows move one row through conflicts, then staged, then unstaged. ⇧-arrows extend across that same painted order, so they can include both copies of a path.
- Typeahead matches the file name and selects that row.
- A refresh keeps a row that is still present. A row whose section disappeared follows the remaining copy of that path. A different repository root clears the selection. `setRoot` clears it immediately.

Scroll identity is the section plus the path (F-UI11). Arrow order is unchanged.

Return opens the merge tool for a conflict and `openChangeDiff` otherwise (today). These keys apply only while the list is focused, so the editor keeps ⌘S for save:

- ⌘S stages every selected path that has an unstaged side.
- ⌘U unstages every selected path that has a staged side.
- A path with both sides is staged or unstaged according to the key, not according to which copy was primary.

After a stage, selection stays on that path. If the path remains in the other section, the primary row follows the side the command did not just clear. Example: staging the last unstaged hunk of a file that was only unstaged moves the primary row to the staged section. If both sides remain, the primary row stays on the section that had focus.

## Stage and unstage

**Entry.** Row plus or minus (today). Context menu Stage or Unstage (target), acting on the selection when the row is inside it. Palette and list keys (target). Stage All and Unstage All stay in the overflow menu.

**Progress.** `isBusy`, caption “Staging…” or “Unstaging…”.

**Cancel.** The user cannot cancel a stage that has entered the lane. Closing the window cancels the window’s wait. The mutation already running finishes. This is the contract. The UI does not add a cancel button for stage.

**Error.** `actionFailed`, Git’s message, list unchanged until the follow-up status. A path with a glob character stages only that path (`--literal-pathspecs` is already on `stage`).

**Focus.** Stays on the list if the list was focused. The commit field does not take focus.

Hunk stage is specified under Diff.

## Commit and amend

**Entry.** Commit button, ⌘↩ in the field (today), Commit and Push… (⌥⌘K, today), palette Git: Commit Staged (target).

**Enabled.** Non-empty trimmed message, and either some staged file or amend, and not `isBusy`. Otherwise the button stays disabled and the palette command `fail`s with “Stage files to commit them” or “Enter a commit message”, matching the button help.

**Sequence.**

1. Focus stays where it was.
2. `IDEGitCommitChecks` runs. Blocking findings open the sheet and do not call `commitIndex`. Warnings offer Commit Anyway.
3. Caption “Committing…”.
4. Success: `resetAfterCommit` clears the message, the selection, the preview, and the one-shot amend flag. `actionStatus` reports the result.
5. Failure: message text stays, `actionFailed` is true, index is whatever Git left.

**Amend.** The checklist toggle prefills the previous message once (today). The button title is Amend while the toggle is on (today). A successful amend turns the toggle off (today, via `resetAfterCommit`).

**Commit and Push.** Commit as above. On success, present the push sheet. On commit failure, do not present it.

**Focus after success.** The field remains focused and empty, so another commit can be typed. Focus after a sheet (checks, push) returns to the field when the sheet closes, which is AppKit’s sheet behavior. Do not move focus to the editor.

## Discard

**Entry.** Context menu “Discard Changes…”, overflow “Discard All…”, Git ▸ “Discard Changes in File…”, palette title updated with the command.

**Sequence.**

1. The confirm sheet names the files, says the discard cannot be undone, and says how many open editors have unsaved edits that will be discarded too. Untracked and added files with no `HEAD` blob are listed as skipped and are not deleted. Today’s `revertChanges` copy, with the button label changed from Revert to Discard.
2. Cancel leaves the index, the work tree, and focus unchanged.
3. Confirm runs `revert`. Caption “Discarding…”.
4. Success reloads editors whose files were reverted and drops their unsaved text. `actionStatus` reports the count.
5. Failure shows `showGitNotice` and does not reload.

**Focus.** Returns to the list if the list invoked the command, otherwise to the editor. The sheet is modal, so this is the responder after the sheet.

Log “Revert Commit” is a different command. It creates a commit. It is not renamed.

## Branches

**Entry.** Toolbar `IDEGitBranchPopup` (today), overflow Switch Branch and New Branch… (today), palette checkout of a branch or tag result (today).

**Switch.**

1. `afterSaving` writes unsaved editors. A file that cannot be saved stops the switch. The message names the file. Focus stays in the editor that failed to save.
2. `switchBranch`. Caption “Switching branch…”.
3. If Git refuses because local files are in the way, the smart-checkout sheet offers Stash and Continue (`preservingLocalChanges`) or Force Checkout. Force Checkout confirms a second time and names that tracked files are discarded. Cancel at either sheet leaves `HEAD` where it was.
4. Success: branch label updates, clean tabs reload, tabs whose files disappeared close, history reloads because refs changed.

**New branch.** Sheet or alert asks for the name. Empty and leading `-` fail before Git runs (today). Success switches to the new branch and does not reload editors beyond the normal switch path. Creating a branch at `HEAD` does not dirty the work tree. Today, `createBranch` switches. Keep that.

**Focus.** The popup closes and focus returns to the editor. A validation failure keeps the name field focused.

## Fetch, update, push

**Fetch.** Menu, overflow, popup. Progress row. Result in `actionStatus` (“Already up to date” or a count). No editor reload unless refs moved and the follow-up status says files changed. Credentials: the askpass sheet. Dismissing it fails the fetch with Git’s message. Background fetch never opens that sheet (today).

**Update Project.** Sheet: Merge or Rebase, default from `pull.rebase` and the last choice, “Don’t ask again” stored in settings. Autostash on. A stop (conflicts) shows the operation banner and does not set `refreshState` to `.failed`. A thrown error sets `actionFailed` and keeps the snapshot.

**Fast-Forward and Fast-Forward & Push.** The sync section only. They call `pull()` which is fast-forward only. A diverged branch sets `actionFailed` with Git’s message and does not open the update sheet. The help text stays “fast-forward only”. People who want a merge use Update Project.

**Push.** Sheet shows outgoing commits, remote, branch, set-upstream, and force-with-lease. Force-with-lease on a protected branch (`main`, `master`, and the user’s globs) calls `fail` before Git runs (today). Cancel leaves the remote untouched.

**Focus.** Sheets return focus to the control that opened them. Progress does not move focus.

## History

**Entry.** Bottom tab “History” (today). Git ▸ Show History for File narrows `historyFilePath` and shows the tab (today). Line history replaces the log until “All Commits” (today).

**Loading.** Until the first `loadHistory` for this root finishes, the empty label is “Loading history…”. After that, an empty result is “No commits” or “No commits touched this file”.

**List.** Arrows, typeahead, ⌘/⇧-click (today). Return opens the selected commit’s patch behavior as today (the detail pane). Load More adds 300 and keeps the selection.

**Commit menu.** Unchanged: checkout, compare, cherry-pick, revert commit, branch, tag, reset, undo, reword, squash, fixup, drop, interactive rebase, push up to here. Reset’s hard mode and Drop stay confirmed. A stop during cherry-pick, revert, or rebase shows the banner.

**Focus.** Showing the bottom tab does not steal editor focus (today, no `ideSidebarFocus` on the history panel). File history from the Git menu shows the tab and leaves editor focus. That stays.

The log does not reload on stage or save. It reloads on `noteRefsChanged`. The spec does not change that.

## Stash

**Entry.** Git ▸ Stash Changes…, the overflow menu, Unstash… which selects the Stashes sub-tab.

**Sheet.** Message, include untracked, keep staged. Cancel leaves the stash list unchanged. Success refreshes status and the log.

**List.** Apply, Apply and Restore Staged Changes, Pop, New Branch from Stash…, Copy Revision, Drop… (confirmed), Clear All… (confirmed). A conflicting apply keeps the stash and shows the banner. Today. No change.

**Focus.** After the sheet, focus returns to the control that opened it. After Unstash…, focus moves to the stash list because that command’s purpose is to show it.

## Conflicts

**While `repositoryState.operation` is set.** The banner is the first control in Changes. Title from `IDEGitOperationPresentation`. Subtitle includes the step when Git wrote one, and the conflict count.

| Control | Enabled | Action | Focus after |
|---|---|---|---|
| Resolve… | A conflict exists | `openMergeTool` on the first conflicted path | Merge tab |
| Continue | No conflicts, not busy | Merge asks for the message first. Others continue | Banner disappears on success. On a stop, the banner updates |
| Skip | Rebase, cherry-pick, or revert | `skipOperation` | Banner updates |
| Abort | Not busy | Confirm, then `abortOperation` | Banner disappears. List refreshes |

**Rows.** Merge…, Accept Yours, Accept Theirs, Open File. Accept Yours and Accept Theirs do not ask again. They call `resolve(paths:taking:)`. A failure stays in `actionStatus`. Double-click and Return open the merge tool.

**Editor banner (target).** Visible when `status(for:)` is `.conflicted`. Merge… opens the same tool. The banner hides when the status is no longer conflicted. It does not appear because the buffer contains conflict markers.

**Next conflict (target).** From the open file, or from the first conflict if the open file is not conflicted, open the merge tool on the next path in `conflictedChanges`. At the end, stay on the last and set `actionStatus` to “No further conflicts”.

**Merge tab.** Today’s behavior stays. Previous and next change are ⇧F7 and F7. ⌥ on a chevron appends. Apply (⌘↩) writes the result, `git add`s, closes the tab, and reloads clean editors. A deleted side shows the message that points at Accept Yours or Theirs. Continue in the banner stays disabled until that file leaves `conflictedChanges`.

## Diff

### Opening

- Changes: double-click, Return, or the expand button opens a tab with `IDEDiffRequest.change` for the selected row’s section. A conflict opens the merge tool. The sidebar preview is that same request. A caller that has only a path still prefers the unstaged side when both exist.
- A rename or copy uses porcelain `originalPath` on the side whose code is `R` or `C`. The other side keeps the current path. A missing `originalPath` is not guessed. An unstaged `mv` that Git reports as a deletion plus an untracked file stays two rows. A comparison of two paths is staged or unstaged as a whole file; a hunk patch is refused with “This change renames or copies the file. Stage or unstage the whole file.”
- History file list: click embeds, double-click opens a tab (today).
- Git ▸ Show Diff with HEAD, Compare with Branch, Compare with Clipboard (today).

Same `IDEDiffRequest.id` selects the existing tab.

### Inside the viewer

Today, and kept:

| Key or control | Action |
|---|---|
| F7 | Next hunk. Past the last, next file |
| ⇧F7 | Previous hunk. Past the first, previous file |
| F4 | Jump to source at the mapped line |
| Layout picker | Side-by-side or unified. Persisted |
| Collapse | Folds unchanged regions to three lines of context |
| Synchronize scrolling | Maps through chunks. Off means the sides scroll independently |
| Chevron | Left side replaces the right hunk. ⌥ appends. One undo step. Disabled when the right side is read-only or the session is stale |
| Plus / minus on the ribbon | `applyToIndex` |

**Hunk apply.**

1. If the right side is dirty or an editor for that path is unsaved, set `session.message` to “Save the file before staging hunks. Unsaved editor text is not written to the index.” Do not call Git.
2. If the path cannot be quoted, or the hunk is only a final newline, set the message that tells the person to stage the whole file.
3. Otherwise `GitHunkApply` with the blob id from load. Caption on the session, not on the Changes commit line.
4. Success: reload the session and refresh status. The list moves the file between sections when the last hunk of that side is gone.
5. Blob mismatch or a rejected patch: `session.message` is Git’s message. The snapshot is not cleared. The list refreshes and may show that another writer won.

Two viewers on the same file can both attempt a hunk. The lane serializes them. The second fails the blob check. Show that message in the viewer that lost. Do not disable the second viewer.

**Editable right side.** Only a working-tree side, and only when no editor tab holds unsaved text for that path. Edits mark the session dirty and recompute after 200 ms. ⌘S writes the file after the on-disk check. A disk change the session did not make asks before overwrite. Closing or switching files saves first.

**Binary.** The viewer shows its binary state and no hunk buttons. The Changes row still stages the whole file with the row control.

**Empty.** An added empty file shows an empty right side and no hunks. Stage the file from the row.

## Errors

| Source | Where it appears | What it must not do |
|---|---|---|
| Status command failed | Refresh caption, error color. Last rows stay | Hide the tab after a snapshot has existed. Clear `changes` |
| First status failed | The failed-empty panel | Look like a folder that is not a repository |
| Not a repository | Chrome hidden | Show an error |
| Mutation failed | `actionStatus`, error color, and the console | Set `refreshState` to `.failed` |
| Operation stopped | Banner | Set `actionFailed` |
| Hunk rejected | `session.message` | Apply a partial patch the user cannot see |
| Cancelled load | No change | Publish an empty snapshot |
| `index.lock` on a status | `.failed` or keep-last, per the contract’s follow-up | Clear the branch label |

`actionStatus` from a success stays until the next action replaces it. A failure stays until the next action or until the person starts another one. Do not auto-dismiss a failure on a timer.

## Keyboard map (target)

Global keys are menu shortcuts. List keys fire only when the Changes list is focused. Diff keys fire only when a diff text view handles them.

| Action | Default, Sublime, VS Code | IntelliJ | Scope |
|---|---|---|---|
| Toggle Changes | ⌃⌘G | ⌘K, ⌘9 | Global, today |
| Focus commit message | Palette, and Escape from the list | same | List and palette |
| Commit | ⌘↩ in the field. Palette command otherwise | same | Field |
| Commit and Push… | ⌥⌘K | same | Global, today |
| Stage selection | ⌘S while the list is focused, palette | same | List focused. ⌘S in the editor still saves |
| Unstage selection | ⌘U while the list is focused, palette | same | List focused |
| Open diff | Return, palette | same | List |
| Next / previous hunk | F7 / ⇧F7 | same | Diff view, today |
| Next / previous editor change | F7 / ⇧F7 when the diff view is not focused | Palette only. F7 stays Step Into | Editor |
| Jump to source | F4 | same | Diff view, today |
| Update Project | Palette | ⌘T | Global, today |
| Push… | Palette | ⇧⌘K | Global, today |
| Discard file | Palette | ⌥⌘Z | Global |
| Next conflict | Palette, Git menu | same | Global, unbound |
| Show history for file | Palette, Git menu | same | Global, today |

Stage and unstage are not global, so ⌘S in the editor keeps saving.

## Focus summary

| Event | Focus |
|---|---|
| Shortcut shows Changes | Commit field |
| Click shows Changes | Unchanged |
| Escape in the field | Editor |
| Escape in the list | Commit field |
| Down Arrow in the field | List, and select the first row if none |
| Sheet opens | Sheet |
| Sheet cancels or completes | The control that presented it, or the field after a commit sheet |
| Stage, unstage, discard from the list | List |
| Switch branch success | Editor |
| Switch branch blocked on save | The editor that did not save |
| Open diff or merge | That tab |
| Hunk apply | The diff view |
| Next editor change | The caret in the editor, on the span’s first line |
