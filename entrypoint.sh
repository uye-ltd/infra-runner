#!/bin/bash
set -euo pipefail

GITHUB_ORG="${GITHUB_ORG:?GITHUB_ORG is required}"
RUNNER_NAME="${RUNNER_NAME:-$(hostname)}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,x64}"

# Registration token must be pre-fetched and injected by the controller.
# The token is short-lived (~1h) and is fetched immediately before container start.
REG_TOKEN="${RUNNER_REGISTRATION_TOKEN:?RUNNER_REGISTRATION_TOKEN is required — must be injected by the controller}"

# Configure in ephemeral mode: the runner auto-deregisters after exactly one job.
# No cleanup trap needed — --ephemeral handles deregistration automatically.
./config.sh \
  --url "https://github.com/${GITHUB_ORG}" \
  --token "${REG_TOKEN}" \
  --name "${RUNNER_NAME}" \
  --labels "${RUNNER_LABELS}" \
  --unattended \
  --ephemeral

printf '{"ts":"%s","level":"info","svc":"runner","msg":"Runner registered (ephemeral). Starting."}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
exec ./run.sh
