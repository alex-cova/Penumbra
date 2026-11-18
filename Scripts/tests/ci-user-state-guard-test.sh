#!/usr/bin/env bash
# Exercise the guard without touching the host's settings or global npm installation.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/umbra-state-guard-test.XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/bin" "${tmp}/home/Library/Preferences" "${tmp}/global" "${tmp}/runner"
cat > "${tmp}/bin/npm" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${TEST_NPM_ROOT}"
SH
cat > "${tmp}/bin/defaults" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "${tmp}/bin/npm" "${tmp}/bin/defaults"
touch "${tmp}/global/package"
export HOME="${tmp}/home" RUNNER_TEMP="${tmp}/runner" PATH="${tmp}/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export TEST_NPM_ROOT="${tmp}/global"
"${root}/Scripts/ci-user-state-guard.sh" snapshot
# Simulate the isolated npm prefix and a tripwire replacing npm after the snapshot.
export TEST_NPM_ROOT="${tmp}/other" npm_config_prefix="${tmp}/other"
cat > "${tmp}/bin/npm" <<'SH'
#!/usr/bin/env bash
exit 127
SH
"${root}/Scripts/ci-user-state-guard.sh" verify
support="${HOME}/Library/Application Support/com.umbra.editor"
mkdir -p "${support}"
"${root}/Scripts/ci-user-state-guard.sh" verify
touch "${support}/unexpected.json"
if "${root}/Scripts/ci-user-state-guard.sh" verify > "${tmp}/diff" 2>&1; then
  echo 'error: guard did not detect a new Application Support file' >&2
  exit 1
fi
grep -q 'app-support.txt' "${tmp}/diff"
rm "${support}/unexpected.json"
rm "${tmp}/global/package"
if "${root}/Scripts/ci-user-state-guard.sh" verify > "${tmp}/diff" 2>&1; then
  echo 'error: guard did not detect a change to the original npm tree' >&2
  exit 1
fi
if ! grep -q 'npm-global.txt' "${tmp}/diff"; then
  cat "${tmp}/diff" >&2
  exit 1
fi
echo 'user-state guard regression test passed'
