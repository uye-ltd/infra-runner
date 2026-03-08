#!/bin/bash
set -euo pipefail

GITHUB_TOKEN="${GITHUB_TOKEN:?GITHUB_TOKEN is required}"
GITHUB_ORG="${GITHUB_ORG:?GITHUB_ORG is required}"
RUNNER_NAME="${RUNNER_NAME:-$(hostname)}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,x64}"

# Obtain a short-lived registration token
REG_TOKEN=$(curl -fsSL \
  -X POST \
  -H "Authorization: token ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/orgs/${GITHUB_ORG}/actions/runners/registration-token" \
  | jq -r '.token')

if [[ -z "${REG_TOKEN}" || "${REG_TOKEN}" == "null" ]]; then
  echo "ERROR: Failed to obtain registration token. Check GITHUB_TOKEN and GITHUB_ORG." >&2
  exit 1
fi

# Configure the runner
./config.sh \
  --url "https://github.com/${GITHUB_ORG}" \
  --token "${REG_TOKEN}" \
  --name "${RUNNER_NAME}" \
  --labels "${RUNNER_LABELS}" \
  --unattended \
  --replace

# Deregister on shutdown
cleanup() {
  echo "Deregistering runner..."
  ./config.sh remove --unattended --token "${REG_TOKEN}" || true
}
trap cleanup SIGTERM SIGINT

echo "Runner registered. Starting..."
exec ./run.sh
