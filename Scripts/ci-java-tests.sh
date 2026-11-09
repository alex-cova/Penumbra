#!/usr/bin/env bash
# Java completion and navigation regression tests for CI.
#
# Runs against the test bundle that `swift build --build-tests` already produced, so it adds only
# test time. The suites that need a window server are left out: add them here once the runner
# is known to have one (see "Java completion remediation plan", task 1.3): that includes
# JavaCompletionControllerTests (a real TextView and controller), which needs a window server.
#
# A missing JDK is a failure, not a skip: the corpus tests skip silently without one, which is how
# this suite once ran nothing (UMBRA_REQUIRE_JDK turns that skip into a failure).
set -euo pipefail

cd "$(dirname "$0")/.."

if ! /usr/libexec/java_home >/dev/null 2>&1 && [ -z "${JAVA_HOME:-}" ]; then
    echo "error: no JDK found (java_home failed and JAVA_HOME is unset); the Java corpus needs one with ct.sym" >&2
    exit 1
fi

# One place for the list. Add a suite here, not in the workflow.
SUITES=(
    JavaCompletionCorpusTests
    JavaCompletionEnginePipelineTests
    JavaNavigationCorpusTests
    CompletionEngineTests
    JavaCompletionProviderContextTests
    JavaRepairedTextEquivalenceTests
    JavaBrokenStatementRepairTests
    JavaStubReuseTests
    ParseEditDiffTests
    JavaBytePositionTests
    JavaIndexPathsTests
    JavaIndexTests
    JavaMemberLookupTests
    JavaParseMemoTests
    JavaDeclaringFileMemoTests
)
filter="$(IFS='|'; echo "${SUITES[*]}")"

export UMBRA_REQUIRE_JDK=1
exec swift test --skip-build --filter "$filter"
