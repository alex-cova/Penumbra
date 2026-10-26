# Harness gap 5: git workflow and worktrees

Part of the series `agent-harness-1.md` to `agent-harness-7.md` (index: `README.md`). Checked against the code on 2026-10-26.

**Status:** open. Phase 1 is small and fixes a real problem (commits fail under the command sandbox).

## What exists today

- **GitIntelligence covers the git operations.** `GitRepository` (`Packages/GitIntelligence/Sources/GitIntelligence/GitRepository.swift`): `discover(from:)`, `status`, `currentBranch`, `branches`, `log(scope:grep:author:path:paths:since:until:skip:limit:)`, `stage(paths:)`, `commit(message:paths:untrackedPaths:amend:signoff:skipHooks:)`, `createBranch(_:)`, `switchBranch(_:)`, push, pull, and in extensions `createBranch(_:startPoint:checkout:)`, `deleteBranch`, `merge`, `rebase`, `compare(_:_:commitLimit:)`, stash, tags, cherry-pick, reset, blame, conflict resolution.
- **There are no worktree operations.** The word in GitIntelligence means the porcelain `Y` column (`worktreeCode`), the `--worktree` flag of `git restore`, and detection of a *linked* worktree (`discover` asks for `--absolute-git-dir`, so `.git/worktrees/<name>` works). Nothing runs `git worktree add/list/remove`.
- **Umbra's own UI already commits.** `IDEChangesPanel` (`Umbra/Sources/Umbra/Git/IDESourceControlPanel.swift`) and `IDEGitStatus.commit()` / `createBranch` / `switchBranch`.
- **The agent has two git tools**, both `.read`: `IDEGitStatusTool` and `IDEGitDiffTool` (`Umbra/Sources/Umbra/Agent/IDEAgentGitTools.swift`). They go to GitIntelligence directly through `IDEAgentGitSource` (project root, `secretPatterns`, unsaved buffers, a `GitRunning`), not through `IDEGitStatus`. The tool shape: a struct conforming to `AgentTool` with `risk`, `definition` (`ToolDefinition(name:description:parameters:)`) and `run(_:context:)`; credential files are filtered by `SecretFilePolicy`; output is capped (12,000 per file, 60,000 total). They are registered in `IDEAgentConversation.currentSession` only when `GitRepository.discover(from: root)` succeeds.
- **`run_command` knows nothing about commits.** `PermissionPolicy` order: deny rule, gate, ask rule, allow rule, mode. In Auto, only `SafeCommands` run unasked; its `gitReaders` are `status, diff, log, show, blame, rev-parse, ls-files, shortlog, describe, grep` (plus `git branch` with list flags). `git commit`, `push` and `checkout` always ask. `CommandWarnings` warns about force-push, `reset --hard` and `clean -f` but never blocks.
- **The command sandbox breaks commits.** `IDEAgentSandbox` makes `.git` read-only, so `git commit` through `run_command` is denied with "Run commands in a sandbox" on. Edit tools are also kept out of `.git` (`WriteProtection`).
- **One agent root per window.** `IDEWorkspace.agentProjectRoot` is `project.rootURL`, or an Application Support scratch folder in AI mode with no project. `IDEAgentConversation` builds `IDEAgentWorkspace(root:)` from `host.agentProjectRoot` in several places. `PathJail` (`Packages/AgentKit/Sources/AgentKit/Workspace/PathJail.swift`) confines tools to that root. A chat cannot have its own root today.
- **The Changes tab compares against this chat's checkpoints,** not git. `IDEAIChangedFiles.summarize` merges the transcript's `.changes` entries; the only action on the whole set is Revert All, and there is no per-file revert on purpose.
- **Navigation tools use the window's index.** `agentJavaNavigator()` answers from `navigationEngine`, which is built for the window's project root.
- **Trust is per path.** `ProjectTrustStore` (`Sources/JavaIntelligence/Gradle/ProjectTrustStore.swift`), asked through `IDEProjectTrustGate`, so a new folder asks again.

## Gap

- The agent cannot commit, branch or read history in a structured way, and a commit through `run_command` fails with the sandbox on.
- Two chats in one project still edit the same working tree. `IDEAgentFileClaims` turns a clash into an approval; it does not isolate. Claude Code and OpenCode run parallel sessions in git worktrees.

## What Claude Code and OpenCode do

- Commit and PR creation are a first-class flow: read the diff and recent log, write the message in the repo's style, commit only when asked, never amend or skip hooks unasked.
- Parallel sessions each get a worktree and a branch; the user reviews and merges the result.

## Proposal

**Phase 1: git tools (S to M).** In `IDEAgentGitTools.swift`, following `IDEGitStatusTool`:
1. `git_log` (`.read`): recent commits (hash, author, date, subject), optional path, limit capped; lets the model match the repo's message style.
2. `git_commit` (`.command`, always asks): `message`, `paths` (explicit; no "commit everything" default), stages them and commits through `GitRepository.commit`. `amend` and `skipHooks` are always false; `signoff` follows the repo's config. The approval card shows the message and the file list (`approvalRequest`). Files that `SecretFilePolicy` blocks are refused. Runs in-process, so the sandbox does not matter.
3. `git_branch` (`.command`): create and switch only. No delete, no force switch.
4. Never push from a tool. Pushing stays a `run_command` with its normal approval.

**Phase 2: `/pr` skill (S).** A bundled skill that reads `git_log`/`git_diff` against the base branch and drives `gh pr create` through `run_command`. No new network surface in the harness.

**Phase 3: a root per chat (M).** An optional `rootOverride: URL?` on `IDEAgentConversation`, used everywhere `host.agentProjectRoot` is read today, saved in the chat. Needed before worktrees, and useful alone.

**Phase 4: worktree operations in GitIntelligence (M).** `worktreeAdd(path:branch:startPoint:)`, `worktreeList()`, `worktreeRemove(path:force:)`, with a parser for `git worktree list --porcelain`, tested against a temp repository.

**Phase 5: "New chat in worktree" (L).**
1. Create the worktree under Application Support (inside the app container, so no extra folder grant), on a new branch named from the chat title. Keep a manifest of the worktrees Umbra created; only those are ever removed.
2. The chat's root becomes the worktree (phase 3); `PathJail` keeps the agent out of the main tree. The editor opens the worktree folder.
3. The Changes tab gets "vs base branch" using `compare`, with Merge, Open PR (the `/pr` skill) and Discard (removes worktree and branch after confirmation, verifying the path is in the manifest).
4. Caveats to handle: navigation and symbol tools answer from the window's index, not the worktree (turn them off in worktree chats or say so in their output); a worktree should inherit the main repository's Gradle, Maven and language-server trust instead of asking again; the first build in a new worktree is cold.

## Rules to keep

- Commands always ask (existing decision). A commit is a command-level action and shows exactly what it will do.
- Worktrees live outside the repo. Discard checks the path against the manifest before deleting anything.
- No force flags, no history rewriting and no push from a tool.

## Tests

- GitIntelligence: worktree add/list/remove and porcelain parsing against a temp repo (`Packages/GitIntelligence/Tests`).
- `IDEAgentGitTools` tests (`Umbra/Tests/UmbraTests`): `git_commit` approval card contents, refusal of a secret file, no `amend` or `skipHooks` path, `git_log` caps.
- A chat with a root override reads and writes only its worktree, and the main tree is untouched.

## Done when

With the sandbox on, the agent commits two named files through `git_commit` after the user approves the card; a chat started in a worktree edits there while the main tree stays clean, and Discard removes only that worktree and branch.

## Size

Phase 1: S to M. Phase 2: S. Phase 3: M. Phase 4: M. Phase 5: L.

## Open questions

- Should `git_commit` be allowed in Auto mode when the user has an allow rule for it, or always ask?
- Where do worktrees live when the project is itself outside the sandbox container: still Application Support, or next to the repo with a user-granted location?
