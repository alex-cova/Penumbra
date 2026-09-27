#!/usr/bin/env bash
# Fails when legacy iOS private-API patterns reappear in Penumbra sources.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

patterns=(
  'NSClassFromString\("UI'
  'value\(forKey: "_'
  'NSSelectorFromString\("replace'
  'UITextRangeAdjustmentGestureRecognizer'
  '_UIScrollPocket'
  'KeyboardObserver'
  'UITextSearchingHelper'
  'UIFindInteraction'
  'UIMenuController'
  'UIApplication\.didReceiveMemoryWarningNotification'
)

failed=0
for pattern in "${patterns[@]}"; do
  if matches="$(rg -n "$pattern" Sources/Penumbra 2>/dev/null || true)"; then
    if [[ -n "$matches" ]]; then
      echo "error: forbidden iOS carryover pattern: $pattern"
      echo "$matches"
      failed=1
    fi
  fi
done

if [[ "$failed" -ne 0 ]]; then
  echo "check-ios-carryover: failed"
  exit 1
fi

echo "check-ios-carryover: ok"
