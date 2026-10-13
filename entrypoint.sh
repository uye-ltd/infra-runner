#!/bin/bash
# Runner container entrypoint. The controller injects exactly one of:
#
#   RUNNER_JITCONFIG           (default) single-use JIT config from
#                              POST /orgs/{org}/actions/runners/generate-jitconfig.
#                              Already registered and ephemeral; no config.sh step.
#   RUNNER_REGISTRATION_TOKEN  (legacy, RUNNER_REGISTRATION_MODE=token) org
#                              registration token, reusable for ~1 h.
#
# In both cases the secret is removed from the environment before `exec run.sh`,
# so job steps (untrusted code from public repos) do not inherit it. A leaked
# registration token would let a job register rogue runners in the org and
# intercept other repositories' jobs.
set -euo pipefail

log() {
  printf '{"ts":"%s","level":"%s","svc":"runner","msg":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2"
}

if [[ -n "${RUNNER_JITCONFIG:-}" ]]; then
  jit="${RUNNER_JITCONFIG}"
  unset RUNNER_JITCONFIG
  log info "Starting ephemeral runner from JIT config"
  # The config remains visible in this process's argv. That is acceptable: a JIT
  # config is single-use and is consumed by the time any job step runs.
  exec ./run.sh --jitconfig "${jit}"
fi

GITHUB_ORG="${GITHUB_ORG:?GITHUB_ORG is required}"
RUNNER_NAME="${RUNNER_NAME:-$(hostname)}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,x64}"
REG_TOKEN="${RUNNER_REGISTRATION_TOKEN:?RUNNER_JITCONFIG or RUNNER_REGISTRATION_TOKEN must be injected by the controller}"
unset RUNNER_REGISTRATION_TOKEN

# Ephemeral: the runner auto-deregisters after exactly one job.
./config.sh \
  --url "https://github.com/${GITHUB_ORG}" \
  --token "${REG_TOKEN}" \
  --name "${RUNNER_NAME}" \
  --labels "${RUNNER_LABELS}" \
  --unattended \
  --ephemeral
unset REG_TOKEN

log info "Runner registered (ephemeral). Starting."
exec ./run.sh
