#!/usr/bin/env bash
# Umbra unit suite, minus live-agent tests and the quarantined stress test, then a check that the
# deterministic ACP suites actually ran (an all-skipped suite would otherwise look green).
#
# Needs a live display (see CLAUDE.md "Common commands"); caffeinate keeps it on.
set -uo pipefail

cd "$(dirname "$0")/.."

TMP="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
RESULTS="${TMP}/results"
XUNIT="${RESULTS}/umbra.xml"
LOG="${RESULTS}/umbra.log"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
mkdir -p "${RESULTS}"
rm -f "${XUNIT}" "${XUNIT%.xml}-swift-testing.xml" "${LOG}"

# ExternalACPLiveTests drives real agent CLIs. The concurrent-edit stress test is quarantined
# on CI after its initial outline intermittently failed to appear; it still runs locally and under TSan.
caffeinate -u -d -i -s swift test --package-path Umbra \
  --skip-build \
  --skip 'ExternalACPLiveTests|IDEConcurrentEditStressTests' \
  --xunit-output "${XUNIT}" 2>&1 | tee "${LOG}"
test_status=$?

check_status=0
/usr/bin/python3 -I - "${SUMMARY}" "${LOG}" "${XUNIT%.xml}-swift-testing.xml" <<'PY' || check_status=$?
import re, sys
from pathlib import Path
import xml.etree.ElementTree as ET

summary, log, swift_testing_xml = sys.argv[1:]
# Suites that are deterministic and must run fully: no skips, no failures.
must_run = re.compile(r"(^|\.)(IDEACP\w*Tests|UmbraACPAgentParityTests)$")

# SwiftPM's serial XCTest run on macOS reports cases in its console output.
# The Swift Testing XML is separate and may be the only XML SwiftPM writes.
xctest_line = re.compile(r"^Test Case '-\[([\w.]+) (\w+)\]' (started|passed|failed|skipped)\b")
cases = {}
with open(log, encoding="utf-8", errors="replace") as source:
    for line in source:
        match = xctest_line.match(line)
        if match:
            suite, test, status = match.groups()
            cases[suite, test] = status

classes = {}
def record(suite, status):
    counts = classes.setdefault(suite, {"passed": 0, "skipped": 0, "failed": 0, "started": 0})
    counts[status] += 1

for (suite, _), status in cases.items():
    record(suite, status)

if Path(swift_testing_xml).is_file():
    root = ET.parse(swift_testing_xml).getroot()
    for case in root.iter("testcase"):
        name = case.get("classname", "")
        if case.find("failure") is not None or case.find("error") is not None:
            record(name, "failed")
        elif case.find("skipped") is not None:
            record(name, "skipped")
        else:
            record(name, "passed")

acp = {k: v for k, v in classes.items() if must_run.search(k)}
problems = []
if not any(must_run.search(suite) for suite, _ in cases):
    problems.append("no IDEACP* or UmbraACPAgentParityTests cases found in the XCTest log")
for name, v in sorted(acp.items()):
    if v["skipped"] or v["failed"] or v["started"]:
        problems.append(f"{name}: {v['passed']} passed, {v['skipped']} skipped, {v['failed']} failed, {v['started']} unfinished")

lines = [
    "### Umbra unit tests",
    f"- total cases: {sum(sum(v.values()) for v in classes.values())}, skipped (env-gated suites included): {sum(v['skipped'] for v in classes.values())}",
    f"- deterministic ACP suites: {len(acp)} ({sum(sum(v.values()) for v in acp.values())} cases)",
]
if problems:
    lines.append("- **ACP suites did not fully run:**")
    lines += [f"  - {p}" for p in problems]
text = "\n".join(lines)
print(text)
with open(summary, "a") as f:
    f.write(text + "\n")
sys.exit(1 if problems else 0)
PY

if [ "${test_status}" -ne 0 ]; then exit "${test_status}"; fi
exit "${check_status}"
