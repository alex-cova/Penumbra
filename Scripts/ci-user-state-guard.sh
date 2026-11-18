#!/usr/bin/env bash
# Proves the tests did not touch the real user's Umbra settings or any global npm install.
#
#   ci-user-state-guard.sh snapshot   record the state (and export isolated npm locations)
#   ci-user-state-guard.sh verify     diff against the snapshot; fail on any difference
#
# Snapshot covers: ~/Library/Application Support/com.umbra.editor, the com.umbra.editor defaults domain,
# com.umbra.editor*.plist files, the global npm tree and ~/.npmrc.
#
# The UI harness uses isolated suites (com.umbra.editor.acp-ui-test.<uuid>) and an isolated app domain
# (com.umbra.editor.acp-ui-test.app). Exclude their plist files and report how many this run created.
set -euo pipefail

BASE="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/user-state"
mkdir -p "${BASE}"

capture() {
  local out="$1"
  mkdir -p "${out}"

  local support="${HOME}/Library/Application Support/com.umbra.editor"
  # Record the contents. A missing root and an empty root both contain no user data.
  : > "${out}/app-support.txt"
  if [ -d "${support}" ]; then
    (cd "${support}" && {
      find . -mindepth 1 ! -type f -print
      find . -type f -exec shasum -a 256 {} +
    } | LC_ALL=C sort) > "${out}/app-support.txt"
  fi

  defaults export com.umbra.editor - 2>/dev/null > "${out}/defaults.plist" || echo "absent" > "${out}/defaults.plist"
  ls -1 "${HOME}/Library/Preferences" 2>/dev/null | grep '^com\.umbra\.editor' | grep -v '^com\.umbra\.editor\.acp-ui-test\.' | sort > "${out}/plists.txt" || true
  ls -1 "${HOME}/Library/Preferences" 2>/dev/null | grep -c '^com\.umbra\.editor\.acp-ui-test\.' > "${out}/ui-suites.count" || true

  if [ -f "${BASE}/npm-root.txt" ]; then
    local root
    root="$(cat "${BASE}/npm-root.txt")"
    if [ -n "${root}" ] && [ -d "${root}" ]; then
      ls -1 "${root}" | sort > "${out}/npm-global.txt"
    else
      echo "absent" > "${out}/npm-global.txt"
    fi
  else
    echo "no-npm" > "${out}/npm-global.txt"
  fi
  if [ -f "${HOME}/.npmrc" ]; then shasum -a 256 "${HOME}/.npmrc" > "${out}/npmrc.txt"; else echo "absent" > "${out}/npmrc.txt"; fi
}

case "${1:-}" in
  snapshot)
    rm -rf "${BASE}/before" "${BASE}/after"
    rm -f "${BASE}/npm-root.txt"
    # Resolve this before changing npm's prefix and before the tripwire shadows npm on PATH.
    # Both captures must inspect the same real global tree.
    if command -v npm >/dev/null 2>&1; then
      npm root -g > "${BASE}/npm-root.txt" 2>/dev/null || true
    fi
    capture "${BASE}/before"
    # Anything that does reach npm lands in the runner's temp directory, not the global prefix.
    if [ -n "${GITHUB_ENV:-}" ]; then
      {
        echo "npm_config_prefix=${BASE}/npm-global"
        echo "npm_config_cache=${BASE}/npm-cache"
        echo "npm_config_userconfig=${BASE}/npmrc"
      } >> "${GITHUB_ENV}"
    fi
    echo "user state snapshot written to ${BASE}/before"
    ;;
  verify)
    if [ ! -d "${BASE}/before" ]; then
      echo "error: no snapshot; run '$0 snapshot' first" >&2
      exit 1
    fi
    capture "${BASE}/after"
    status=0
    if ! diff -ru --exclude=ui-suites.count "${BASE}/before" "${BASE}/after"; then
      echo "error: the tests changed real user state (see diff above)" >&2
      status=1
    fi
    new_suites=$(( $(cat "${BASE}/after/ui-suites.count") - $(cat "${BASE}/before/ui-suites.count") ))
    if [ "${new_suites}" -gt 0 ]; then
      echo "note: this run left ${new_suites} isolated UI-test defaults plist(s) (com.umbra.editor.acp-ui-test.*); not user settings"
    fi
    [ "${status}" -eq 0 ] && echo "user state unchanged"
    exit "${status}"
    ;;
  *)
    echo "usage: $0 snapshot|verify" >&2
    exit 2
    ;;
esac
