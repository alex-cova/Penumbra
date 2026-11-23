#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$root"

# Xcode serves the Metal compiler from an on-demand cryptex mount whose hash
# changes across asset updates
# (…/com.apple.MobileAsset.MetalToolchain-vNN/…/Metal.xctoolchain/usr/bin/metal).
# SwiftPM bakes that absolute path into Umbra/.build, so a later build can fail
# with "unable to spawn process '…/Metal.xctoolchain/usr/bin/metal'
# (No such file or directory)". Dropping the stale build dir and retrying once
# fixes it.
log="$(mktemp -t umbra-run-XXXXXX)"
status=0
swift run --package-path Umbra Umbra "$@" 2>&1 | tee "$log" || status=$?

if [[ $status -eq 0 ]]; then
  rm -f "$log"
  exit 0
fi

if grep -q "unable to spawn process" "$log" && grep -q "Metal.xctoolchain/usr/bin/metal" "$log"; then
  echo "run.sh: stale Metal toolchain path (Xcode's on-demand Metal.xctoolchain mount moved); removing Umbra/.build and retrying once…" >&2
  rm -rf "$root/Umbra/.build"
  rm -f "$log"
  exec swift run --package-path Umbra Umbra "$@"
fi

rm -f "$log"
exit "$status"
