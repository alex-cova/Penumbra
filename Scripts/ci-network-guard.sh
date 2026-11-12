#!/usr/bin/env bash
# Blackholes the hosts a live AI request or a real npm install would reach, so such a call fails
# instead of succeeding. Run it AFTER dependencies are resolved and built, BEFORE tests.
#
# CI only: it edits /etc/hosts with sudo. Refuses to run outside GitHub Actions unless
# UMBRA_ALLOW_HOSTS_EDIT=1, so it cannot be run on a developer Mac by accident.
set -euo pipefail

if [ -z "${GITHUB_ACTIONS:-}" ] && [ "${UMBRA_ALLOW_HOSTS_EDIT:-}" != "1" ]; then
  echo "error: ci-network-guard.sh edits /etc/hosts and is for CI runners only (set UMBRA_ALLOW_HOSTS_EDIT=1 to override)." >&2
  exit 1
fi

HOSTS=(
  api.openai.com
  chatgpt.com
  auth.openai.com
  api.anthropic.com
  claude.ai
  console.anthropic.com
  registry.npmjs.org
)

if grep -q "umbra-ci-network-guard" /etc/hosts; then
  echo "network guard already installed"
  exit 0
fi

{
  echo "# umbra-ci-network-guard"
  for host in "${HOSTS[@]}"; do
    echo "0.0.0.0 ${host}"
    echo "::1 ${host}"
  done
} | sudo tee -a /etc/hosts >/dev/null

sudo dscacheutil -flushcache || true
sudo killall -HUP mDNSResponder || true

# Prove it took effect: the lookup must not resolve to a routable address.
for host in "${HOSTS[@]}"; do
  resolved="$(dscacheutil -q host -a name "${host}" | awk '/ip(v6)?_address/ {print $2}' | sort -u | tr '\n' ' ')"
  case "${resolved}" in
    ""|"0.0.0.0 "|"::1 "|"0.0.0.0 ::1 "|"::1 0.0.0.0 ") ;;
    *) echo "error: ${host} still resolves to ${resolved}" >&2; exit 1 ;;
  esac
done
echo "network guard installed for: ${HOSTS[*]}"
