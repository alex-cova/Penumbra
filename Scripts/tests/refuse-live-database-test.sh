#!/usr/bin/env bash
# Tests that need the disposable database containers (Docker, Scripts/db-test-env.sh) must never run on
# the GitHub pipeline. Checks the three things that keep that true:
#   1. the CI guard refuses every variable that switches those tests on,
#   2. every live test suite also skips itself when GITHUB_ACTIONS is "true",
#   3. no workflow starts the containers or sets those variables.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
guard="${root}/Scripts/refuse-paid-test-variables.sh"
fail() { echo "error: $*" >&2; exit 1; }

# 1. The guard passes with a clean environment and fails for each live-database variable.
env -i PATH="${PATH}" "${guard}" || fail "the guard failed with no variables set"
for name in UMBRA_DB_INTEGRATION UMBRA_TEST_PG_URL UMBRA_TEST_MYSQL_URL UMBRA_TEST_MONGO_URL; do
  if env -i PATH="${PATH}" "${name}=1" "${guard}" >/dev/null 2>&1; then
    fail "the guard did not refuse ${name}"
  fi
done

# 2. Every Swift test file that reads the switch also checks GITHUB_ACTIONS.
status=0
while IFS= read -r file; do
  if ! grep -q 'GITHUB_ACTIONS' "${file}"; then
    echo "error: ${file#"${root}/"} reads UMBRA_DB_INTEGRATION but does not skip under GITHUB_ACTIONS" >&2
    status=1
  fi
done < <(grep -rl 'UMBRA_DB_INTEGRATION' "${root}/Packages/DatabaseKit/Tests" "${root}/Umbra/Tests" "${root}/Tests" 2>/dev/null || true)

# 3. No workflow or composite action starts containers or enables the tests.
if grep -rnE 'db-test-env|UMBRA_DB_INTEGRATION|UMBRA_TEST_(PG|MYSQL|MONGO)_URL|umbra-dbtest|postgis/postgis|mysql:8|mongo:7|services:' \
     "${root}/.github" 2>/dev/null; then
  echo 'error: a workflow starts database containers or enables the live database tests' >&2
  status=1
fi
exit "${status}"
