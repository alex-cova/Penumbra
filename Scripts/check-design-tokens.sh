#!/usr/bin/env bash
# Fails when the core chrome of Umbra uses a literal where a design token exists:
#   .font(.system(size: 11))      -> IDEAppearance.IconSize.* (a symbol) or Typography.* (text)
#   .padding(.horizontal, 6)      -> IDEAppearance.Spacing.*
#   HStack(spacing: 4)            -> IDEAppearance.Spacing.*
# Zero (`spacing: 0`) is not a design choice and stays allowed. A line that really needs a fixed
# value ends with `// token-exempt: <why>`. Feature folders (Agent, Git, Run, Database, ...) are
# not covered yet; add a folder to `folders` once it has been swept.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root/Umbra/Sources/Umbra"

folders=(DesignSystem SharedUI Workspace Explorer Panels App Settings Editor)
patterns=(
  '\.system\(size:[[:space:]]*[0-9]'
  '\.padding\((\.[a-zA-Z]+,[[:space:]]*)?[0-9]'
  'spacing:[[:space:]]*[1-9]'
)

failed=0
for pattern in "${patterns[@]}"; do
  # grep exits 1 for "no match" (fine) and 2 for a real error (a missing folder): that must not pass.
  status=0
  found=$(grep -rnE --include='*.swift' -e "$pattern" "${folders[@]}") || status=$?
  if [[ "$status" -gt 1 ]]; then
    echo "check-design-tokens: grep failed (exit $status) for $pattern" >&2
    exit 2
  fi
  matches=$(printf '%s\n' "$found" | grep -v 'token-exempt' | grep -v '^$' || true)
  if [[ -n "$matches" ]]; then
    echo "error: literal instead of a design token: $pattern"
    echo "$matches"
    failed=1
  fi
done

if [[ "$failed" -ne 0 ]]; then
  echo "check-design-tokens: failed (use IDEAppearance.Spacing / IconSize / Typography, or end the line with // token-exempt: <why>)"
  exit 1
fi

echo "check-design-tokens: ok"
