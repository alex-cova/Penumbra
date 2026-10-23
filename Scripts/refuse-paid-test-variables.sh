#!/usr/bin/env bash
# Fails if a variable that switches on a test which spends money (OpenAI, Anthropic, an Ollama server)
# has a value. Run by CI; also safe to run locally before a push: it only reads the environment.
set -euo pipefail

status=0
for name in AGENTKIT_EVAL AGENTKIT_OPENAI_KEY AGENTKIT_ANTHROPIC_KEY AGENTKIT_META_KEY AGENTKIT_OLLAMA_MODEL AGENTKIT_OLLAMA_URL; do
  if [ -n "${!name:-}" ]; then
    echo "error: $name is set. Tests that call a paid API must not run in CI; remove it from the workflow or its secrets." >&2
    status=1
  fi
done
exit $status
