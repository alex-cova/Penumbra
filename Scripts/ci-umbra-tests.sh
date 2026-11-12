#!/usr/bin/env bash
# Full Umbra unit suite, minus the opt-in live-agent tests, then a check that the deterministic ACP
# suites actually ran (an all-skipped suite would otherwise look green).
#
# Needs a live display (see CLAUDE.md "Common commands"); caffeinate keeps it on.
set -uo pipefail

cd "$(dirname "$0")/.."

TMP="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
RESULTS="${TMP}/results"
XUNIT="${RESULTS}/umbra.xml"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
mkdir -p "${RESULTS}"
rm -f "${XUNIT}" "${RESULTS}/umbra-parallel.xml"

# ExternalACPLiveTests drives the real codex and claude CLIs (UMBRA_LIVE_ACP=1); it never runs in CI.
caffeinate -u -d -i -s swift test --package-path Umbra \
  --skip ExternalACPLiveTests \
  --xunit-output "${XUNIT}"
test_status=$?

# swift test writes <name>.xml and <name>-swift-testing.xml; take whichever exist.
files=()
for f in "${XUNIT}" "${XUNIT%.xml}-swift-testing.xml"; do [ -f "$f" ] && files+=("$f"); done
if [ "${#files[@]}" -eq 0 ]; then
  echo "error: no xUnit output was written" >&2
  exit 1
fi

check_status=0
/usr/bin/python3 -I - "${SUMMARY}" "${files[@]}" <<'PY' || check_status=$?
import re, sys
import xml.etree.ElementTree as ET

summary, files = sys.argv[1], sys.argv[2:]
# Suites that are deterministic and must run fully: no skips, no failures.
must_run = re.compile(r"(^|\.)(IDEACP\w*Tests|UmbraACPAgentParityTests)$")

classes = {}
total_skipped = 0
for path in files:
    root = ET.parse(path).getroot()
    for case in root.iter("testcase"):
        name = case.get("classname", "")
        entry = classes.setdefault(name, {"run": 0, "skipped": 0, "failed": 0})
        entry["run"] += 1
        if case.find("skipped") is not None:
            entry["skipped"] += 1
            total_skipped += 1
        if case.find("failure") is not None or case.find("error") is not None:
            entry["failed"] += 1

acp = {k: v for k, v in classes.items() if must_run.search(k)}
problems = []
if not acp:
    problems.append("no IDEACP* or UmbraACPAgentParityTests cases found in the xUnit output")
for name, v in sorted(acp.items()):
    if v["skipped"] or v["failed"]:
        problems.append(f"{name}: {v['run']} run, {v['skipped']} skipped, {v['failed']} failed")

lines = [
    "### Umbra unit tests",
    f"- total cases: {sum(v['run'] for v in classes.values())}, skipped (env-gated suites included): {total_skipped}",
    f"- deterministic ACP suites: {len(acp)} ({sum(v['run'] for v in acp.values())} cases)",
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
