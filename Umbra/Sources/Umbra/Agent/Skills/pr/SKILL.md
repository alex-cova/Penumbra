---
name: pr
description: Open a pull request for the current branch with gh, after reviewing the diff and recent history.
allowed-tools: [git_log, git_diff, run_command]
---

# Opening a pull request

Open a pull request for the current branch. Never push from a git tool; the one push happens
inside `gh pr create`, which runs through `run_command` with its normal approval.

1. Read `git_log` for the recent subjects, so the title matches the repository's message style.
   Read `git_diff` for what the branch changes.
2. Find the base branch with `run_command`: `git symbolic-ref --short refs/remotes/origin/HEAD`,
   falling back to `main` and then `master` when that prints nothing. The base is the remote name
   without the `origin/` prefix.
3. Review the branch against the base with `run_command`: `git diff <base>...HEAD --stat` and,
   for the details, `git diff <base>...HEAD -- <path>`.
4. Create the request with `run_command`: `gh pr create --base <base> --title "<title>" --body "<body>"`.
   The approval card covers the push `gh` does. When `gh` reports no pull request is needed (the
   branch is up to date with the base), say so and stop.
5. Report the pull request URL `gh` prints.
