#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$root"

# Show the first-run tour on this launch (`swift run` and the bundled app
# persist the flag in different defaults domains).
defaults delete com.umbra.editor com.umbra.editor.hasCompletedFirstRunGuide 2>/dev/null || true
defaults delete Umbra com.umbra.editor.hasCompletedFirstRunGuide 2>/dev/null || true

exec swift run -c release Umbra --metal "$@"
