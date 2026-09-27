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
  'UIKitCompatibility'
  'Penumbra/UIBridge'
  'open class UIView'
  'open class UIScrollView'
  'open class UIPasteboard'
  'open class UIScreen'
  'public final class UIBezierPath'
  'public enum UITextAutocorrectionType'
  'public typealias UIColor'
  'var font: UIColor'
  'var keyboardType:'
)

failed=0
for pattern in "${patterns[@]}"; do
  matches=$(rg -n "$pattern" Sources/Penumbra 2>/dev/null | grep -v 'LegacyUIKitAliases.swift' | grep -v 'Documentation.docc/' || true)
  if [[ -n "$matches" ]]; then
    echo "error: forbidden iOS carryover pattern: $pattern"
    echo "$matches"
    failed=1
  fi
done

if [[ "$failed" -ne 0 ]]; then
  echo "check-ios-carryover: failed"
  exit 1
fi

echo "check-ios-carryover: ok"
