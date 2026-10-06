# GitIntelligence

Loaded when working under `Packages/GitIntelligence`. Moved out of the root CLAUDE.md.

- **`GitIntelligence`** (`Packages/GitIntelligence`) — its own Swift package, no dependencies. `GitRepository` wraps the git CLI (status including ignored paths, stage, commit, staged and unstaged diff, log, `GitGraphLayout`). `visibleFiles(under:)` is `git ls-files -z --cached --others --exclude-standard` as paths relative to a directory (nil when it is not a work tree), which is what `grep`, `glob` and Find in Files search. Umbra wires it through `IDEGitStatus` for explorer colors and the source-control panel (local branch switch and create, push, and fast-forward pull). `fileContents(at:path:)` reads a file at a `GitRevision` (`.head`, `.index`, `.commit`, `.parent(of:)`, `.ref`; nil when that version has no such file) and `applyPatch(_:toIndex:reverse:)` runs `git apply --unidiff-zero` from stdin, for the diff viewer's file sides and hunk staging.
