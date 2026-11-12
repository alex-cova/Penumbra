#!/usr/bin/env bash
# Runs the deterministic ACP Adapter Manager XCUITests (fake registry, fake npm, fake Node ACP agent,
# temporary directories) and fails unless every one of them executed and passed.
#
#   ci-acp-ui-tests.sh                build and test (local use)
#   ci-acp-ui-tests.sh --build-only   build-for-testing only (CI: runs while the network is still open)
#   ci-acp-ui-tests.sh --no-build     test-without-building (CI: after the network guard)
#
# The opt-in ACPAdapterLiveUITests are excluded here and by Scripts/refuse-paid-test-variables.sh.
set -uo pipefail

cd "$(dirname "$0")/.."

# Number of test methods in Umbra/UITests/ACPAdapterManagerUITests.swift. Update with that file.
EXPECTED_TESTS=19

TMP="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
RESULTS="${TMP}/results"
DERIVED="${TMP}/dd"
SPM="${TMP}/spm"
BUNDLE="${RESULTS}/ACPUI.xcresult"
LOG="${RESULTS}/ACPUI.log"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
mkdir -p "${RESULTS}"
rm -rf "${BUNDLE}"

if [ "$(grep -c '^    func test' Umbra/UITests/ACPAdapterManagerUITests.swift)" != "${EXPECTED_TESTS}" ]; then
  echo "error: ACPAdapterManagerUITests.swift no longer has ${EXPECTED_TESTS} tests; update EXPECTED_TESTS in $0" >&2
  exit 1
fi

action="test"
case "${1:-}" in
  --no-build) action="test-without-building" ;;
  --build-only) action="build-for-testing" ;;
esac

xcodebuild "${action}" \
  -project Umbra/Umbra.xcodeproj \
  -scheme UmbraACPUI \
  -destination 'platform=macOS' \
  -derivedDataPath "${DERIVED}" \
  -clonedSourcePackagesDirPath "${SPM}" \
  -resultBundlePath "${BUNDLE}" \
  -only-testing:UmbraUITests/ACPAdapterManagerUITests \
  -skip-testing:UmbraUITests/ACPAdapterLiveUITests \
  -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 120 \
  -maximum-test-execution-time-allowance 300 \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  2>&1 | tee "${LOG}"
xcode_status=${PIPESTATUS[0]}

if [ "${action}" = "build-for-testing" ]; then
  exit "${xcode_status}"
fi

# Classify GUI-automation blockers so the failure names the cause rather than "tests failed".
blocker=""
for pattern in \
  "Failed to initialize for UI testing" \
  "Timed out while enabling automation mode" \
  "Timed out waiting for AX loaded notification" \
  "kAXErrorAPIDisabled" \
  "is not authorized for accessibility" \
  "Unable to launch"; do
  if line="$(grep -m1 -F "${pattern}" "${LOG}")"; then
    blocker="${line}"
    break
  fi
done

passed=0; failed=0; skipped=0; total=0
if [ -d "${BUNDLE}" ]; then
  json="$(xcrun xcresulttool get test-results summary --path "${BUNDLE}" --format json 2>/dev/null || true)"
  if [ -n "${json}" ]; then
    read -r passed failed skipped total < <(printf '%s' "${json}" | /usr/bin/python3 -I -c '
import json, sys
d = json.load(sys.stdin)
print(d.get("passedTests", 0), d.get("failedTests", 0), d.get("skippedTests", 0), d.get("totalTestCount", 0))
')
  fi
fi

{
  echo "### ACP XCUITest"
  echo "| expected | executed | passed | failed | skipped |"
  echo "|---|---|---|---|---|"
  echo "| ${EXPECTED_TESTS} | ${total} | ${passed} | ${failed} | ${skipped} |"
} | tee -a "${SUMMARY}"

status=0
if [ "${total}" != "${EXPECTED_TESTS}" ] || [ "${passed}" != "${EXPECTED_TESTS}" ] || [ "${failed}" != "0" ] || [ "${skipped}" != "0" ] || [ "${xcode_status}" != "0" ]; then
  status=1
  if [ -n "${blocker}" ] && [ "${passed}" != "${EXPECTED_TESTS}" ]; then
    {
      echo
      echo "**GUI automation unsupported on this runner:** \`${blocker}\`"
      echo "The deterministic suite did not execute. This is a failure, not a skip. See docs/CI.md."
    } | tee -a "${SUMMARY}" >&2
  else
    echo "error: expected ${EXPECTED_TESTS} passing, 0 skipped; got passed=${passed} failed=${failed} skipped=${skipped} total=${total} (xcodebuild exit ${xcode_status})" | tee -a "${SUMMARY}" >&2
  fi
fi
exit "${status}"
