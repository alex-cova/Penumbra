#!/usr/bin/env bash
# Fails the job if a real Codex or Claude Code process is started during the tests.
#
#   ci-agent-tripwire.sh start    shims on PATH + a process poller
#   ci-agent-tripwire.sh verify   stop the poller, fail if anything was recorded
#
# The fixture ACP agent is `node …/node_modules/@agentclientprotocol/<name>/dist/index.js` (a script
# the test writes), so those command lines are allowed; a binary or shim named codex/claude is not.
set -euo pipefail

BASE="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/tripwire"
BIN="${BASE}/bin"
HITS="${BASE}/hits"
PIDFILE="${BASE}/poller.pid"

start() {
  rm -rf "${BASE}"
  mkdir -p "${BIN}"
  : > "${HITS}"

  for name in codex claude codex-acp claude-agent-acp; do
    cat > "${BIN}/${name}" <<EOF
#!/bin/sh
echo "shim ${name} invoked: \$0 \$*" >> "${HITS}"
echo "error: ${name} must not run in CI" >&2
exit 127
EOF
    chmod +x "${BIN}/${name}"
  done

  # Real npm must not run in the test steps either; the fixtures write the tree themselves.
  for name in npm npx; do
    cat > "${BIN}/${name}" <<EOF
#!/bin/sh
echo "shim ${name} invoked: \$0 \$*" >> "${HITS}"
echo "error: ${name} must not run during tests" >&2
exit 127
EOF
    chmod +x "${BIN}/${name}"
  done

  if [ -n "${GITHUB_PATH:-}" ]; then
    echo "${BIN}" >> "${GITHUB_PATH}"
  fi

  (
    while true; do
      ps -axo pid=,command= | while read -r pid command; do
        case "${command}" in
          *ci-agent-tripwire*|*pgrep*|*grep*) continue ;;
          *node_modules/@agentclientprotocol/*/dist/index.js*) continue ;;
        esac
        if printf '%s\n' "${command}" | grep -Eq '(^|/)(codex|claude)( |$)|claude-agent-acp|codex-acp/bin|/\.claude/|/\.codex/'; then
          echo "process ${pid}: ${command}" >> "${HITS}"
        fi
      done
      sleep 1
    done
  ) >/dev/null 2>&1 &
  echo $! > "${PIDFILE}"
  disown || true
  echo "tripwire started (shims in ${BIN}, poller $(cat "${PIDFILE}"))"
}

verify() {
  if [ -f "${PIDFILE}" ]; then
    kill "$(cat "${PIDFILE}")" 2>/dev/null || true
    rm -f "${PIDFILE}"
  fi
  if [ ! -f "${HITS}" ]; then
    echo "error: tripwire was never started" >&2
    exit 1
  fi
  if [ -s "${HITS}" ]; then
    echo "error: a real agent or npm was started during the tests:" >&2
    sort -u "${HITS}" >&2
    exit 1
  fi
  echo "tripwire clean: no codex, claude or npm process was started"
}

case "${1:-}" in
  start) start ;;
  verify) verify ;;
  *) echo "usage: $0 start|verify" >&2; exit 2 ;;
esac
