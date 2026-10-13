#!/bin/zsh
# P6 / S3.0 spike: what input can a host drive from inside the app with public API only?
# Builds input-host.swift, installs it on a device Umbra created (never the user's own), runs the
# probe and prints its results. Usage: input.sh [ax-off | ax-on | ax-app | ax-live]
#   ax-off   the device's accessibility preferences as they are (default; clears the two keys first)
#   ax-on    sets both AccessibilityEnabled and ApplicationAccessibilityEnabled before launching
#   ax-app   sets only ApplicationAccessibilityEnabled before launching
#   ax-live  launches first, sets ApplicationAccessibilityEnabled while the app runs, probes later
# The preference is the one Accessibility Inspector and XCUITest flip; SwiftUI vends its
# accessibility tree only while it is on.
set -euo pipefail
here=${0:A:h}
work=$(mktemp -d /tmp/umbra-ios-input.XXXX)
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
device=$(xcrun simctl list devices available | grep 'Umbra Preview' | grep -Eo '[0-9A-F-]{36}' | head -1)
[[ -n $device ]] || { echo "no 'Umbra Preview' device: run the S1/S2 integration test or create one"; exit 1 }
triple=arm64-apple-ios18.0-simulator
bundle=com.umbra.preview.spike

mkdir -p $work/App.app $work/out
xcrun swiftc -sdk $sdk -target $triple -parse-as-library -swift-version 5 $here/input-host.swift -o $work/App.app/host
cp $here/Info.plist $work/App.app/Info.plist
codesign -f -s - $work/App.app

xcrun simctl bootstatus $device -b >/dev/null
mode=${1:-ax-off}
domain=com.apple.Accessibility
clear_ax() {
  xcrun simctl spawn $device defaults delete $domain ApplicationAccessibilityEnabled 2>/dev/null || true
  xcrun simctl spawn $device defaults delete $domain AccessibilityEnabled 2>/dev/null || true
}
clear_ax
case $mode in
  ax-on)
    xcrun simctl spawn $device defaults write $domain ApplicationAccessibilityEnabled -bool true
    xcrun simctl spawn $device defaults write $domain AccessibilityEnabled -bool true ;;
  ax-app)
    xcrun simctl spawn $device defaults write $domain ApplicationAccessibilityEnabled -bool true ;;
esac
xcrun simctl uninstall $device $bundle 2>/dev/null || true
xcrun simctl install $device $work/App.app
delay=1.0; [[ $mode == ax-live ]] && delay=6.0
SIMCTL_CHILD_UMBRA_START_DELAY=$delay SIMCTL_CHILD_UMBRA_OUT_DIR=$work/out \
  xcrun simctl launch --terminate-running-process $device $bundle >/dev/null
if [[ $mode == ax-live ]]; then
  sleep 2
  xcrun simctl spawn $device defaults write $domain ApplicationAccessibilityEnabled -bool true
fi
for _ in {1..120}; do [[ -f $work/out/done ]] && break; sleep 0.5; done
xcrun simctl terminate $device $bundle || true
xcrun simctl uninstall $device $bundle || true
clear_ax
echo "results in $work/out"
cat $work/out/results.txt 2>/dev/null || echo "(no results file: the probe did not finish)"
