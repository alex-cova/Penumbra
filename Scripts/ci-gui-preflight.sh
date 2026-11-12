#!/usr/bin/env bash
# Checks that this machine can drive the Umbra GUI with XCUITest, and names the blocker when it cannot.
# Never skips: any failed check exits non-zero.
#
# It cannot prove the Accessibility (TCC) grant for the test runner ahead of time; that is classified
# from the xcodebuild output by ci-acp-ui-tests.sh.
set -uo pipefail

SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
blockers=()

note() { echo "$*"; echo "$*" >> "${SUMMARY}"; }
block() { blockers+=("$1"); note "BLOCKER: $1"; }

{
  echo "### GUI preflight"
  echo '```'
} >> "${SUMMARY}"

note "macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(uname -m)"
note "user: $(id -un), console owner: $(stat -f%Su /dev/console 2>/dev/null || echo unknown)"
note "launchd session: $(launchctl managername 2>/dev/null || echo unknown)"

# 1. A logged-in GUI session on the console, screen not locked.
session="$(/usr/bin/swift -e '
import Foundation
import CoreGraphics
if let d = CGSessionCopyCurrentDictionary() as? [String: Any] {
    let onConsole = (d["kCGSSessionOnConsoleKey"] as? Bool) ?? false
    let locked = (d["CGSSessionScreenIsLocked"] as? Bool) ?? false
    print("onConsole=\(onConsole) locked=\(locked)")
} else {
    print("onConsole=false locked=false nosession")
}' 2>&1 | tail -n 1)"
note "CoreGraphics session: ${session}"
case "${session}" in
  *nosession*|*onConsole=false*) block "no logged-in GUI session (CGSessionCopyCurrentDictionary has no console session); XCUITest cannot launch Umbra.app" ;;
esac
case "${session}" in
  *locked=true*) block "screen locked" ;;
esac
if [ "$(launchctl managername 2>/dev/null)" != "Aqua" ]; then
  block "launchd session is '$(launchctl managername 2>/dev/null)', not Aqua"
fi

# 2. Automation mode (lets XCTest drive the UI without an interactive authorization prompt).
if command -v automationmodetool >/dev/null 2>&1; then
  note "automationmodetool: $(automationmodetool 2>&1 | head -n 3 | tr '\n' ' ')"
  if ! sudo -n automationmodetool enable-automationmode-without-authentication >/dev/null 2>&1; then
    block "cannot enable automation mode (automationmodetool enable-automationmode-without-authentication failed; needs passwordless sudo)"
  fi
else
  block "automationmodetool not found"
fi

# 3. Node at one of the three paths the UI harness checks (ACPUIHarness.requireNode skips otherwise).
node_path=""
for candidate in /opt/homebrew/bin/node /usr/local/bin/node /usr/bin/node; do
  if [ -x "${candidate}" ]; then node_path="${candidate}"; break; fi
done
if [ -z "${node_path}" ]; then
  block "node missing at /opt/homebrew/bin, /usr/local/bin and /usr/bin; the harness would skip ~12 tests"
else
  note "node: ${node_path} $("${node_path}" --version)"
fi

# 4. Opt-in live variables must be absent.
if ! Scripts/refuse-paid-test-variables.sh 2>>"${SUMMARY}"; then
  block "a variable that enables live or paid tests is set"
fi

echo '```' >> "${SUMMARY}"

if [ "${#blockers[@]}" -gt 0 ]; then
  {
    echo
    echo "**GUI preflight failed (${#blockers[@]}).** The ACP XCUITest suite was NOT run and is NOT counted as passed."
    echo "See docs/CI.md ('GUI automation on hosted runners') for the self-hosted runner setup."
  } | tee -a "${SUMMARY}" >&2
  exit 1
fi
echo "GUI preflight passed"
