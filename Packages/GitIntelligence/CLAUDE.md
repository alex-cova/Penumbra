# GitIntelligence

Loaded when working under `Packages/GitIntelligence`. Moved out of the root CLAUDE.md.

- **`GitIntelligence`** (`Packages/GitIntelligence`) — its own Swift package, no dependencies. `GitRepository` wraps the git CLI (status including ignored paths, stage, commit, staged and unstaged diff, log, `GitGraphLayout`). Umbra wires it through `IDEGitStatus` for explorer colors and the source-control panel (local branch switch and create, push, and fast-forward pull).
