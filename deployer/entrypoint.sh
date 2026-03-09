#!/bin/bash
# GitOps pull-based deployer.
#
# Polls GHCR for new image digests. When a new image is detected it verifies
# the cosign signature (keyless, anchored to the CI workflow OIDC identity)
# before applying the change via docker compose.
#
# Update order:
#   1. deployer itself  (verify → pull → re-create this container → exit)
#   2. controller       (verify → docker compose up -d controller)
#   3. runner image     (verify remote sig → pull)
#
# Health endpoint: GET http://<host>:HEALTH_PORT/health
#   200 {"status":"ok",...}  or  503 {"status":"unhealthy","reason":"..."}
set -euo pipefail

GITHUB_ORG="${GITHUB_ORG:?GITHUB_ORG is required}"
GITHUB_REPO="${GITHUB_REPO:-uye-runner}"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:?COMPOSE_PROJECT_NAME is required}"
POLL_INTERVAL="${POLL_INTERVAL:-60}"
HEALTH_FILE="${HEALTH_FILE:-/tmp/health}"
HEALTH_PORT="${HEALTH_PORT:-8080}"

CONTROLLER_IMAGE="ghcr.io/${GITHUB_ORG}/uye-runner-controller:latest"
RUNNER_IMAGE="ghcr.io/${GITHUB_ORG}/uye-runner:latest"
DEPLOYER_IMAGE="ghcr.io/${GITHUB_ORG}/uye-deployer:latest"

CERT_IDENTITY="https://github.com/${GITHUB_ORG}/${GITHUB_REPO}/.github/workflows/deploy.yml@refs/heads/main"
CERT_OIDC_ISSUER="https://token.actions.githubusercontent.com"

COMPOSE="docker compose --project-name ${COMPOSE_PROJECT_NAME} --project-directory /workspace"

# ---------------------------------------------------------------------------
# Structured JSON logging
# Usage: log <level> <message> [key value ...]
# ---------------------------------------------------------------------------

log() {
  local level="$1" msg="$2"; shift 2
  msg="${msg//\\/\\\\}"; msg="${msg//\"/\\\"}"; msg="${msg//$'\n'/\\n}"
  local kv=""
  while [[ $# -ge 2 ]]; do
    local k="$1" v="$2"; shift 2
    v="${v//\\/\\\\}"; v="${v//\"/\\\"}"; v="${v//$'\n'/\\n}"
    kv="${kv},\"${k}\":\"${v}\""
  done
  printf '{"ts":"%s","level":"%s","svc":"deployer","msg":"%s"%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${level}" "${msg}" "${kv}"
}

# ---------------------------------------------------------------------------
# Health state
# ---------------------------------------------------------------------------

set_healthy() {
  printf '{"status":"ok","ts":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${HEALTH_FILE}"
}

set_unhealthy() {
  local reason="$1"
  local r="${reason//\\/\\\\}"; r="${r//\"/\\\"}"
  printf '{"status":"unhealthy","reason":"%s","ts":"%s"}\n' \
    "${r}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${HEALTH_FILE}"
  log warn "Health → unhealthy" reason "${reason}"
}

# ---------------------------------------------------------------------------
# Image helpers
# ---------------------------------------------------------------------------

image_id() { docker image inspect "$1" --format='{{.Id}}' 2>/dev/null || echo "none"; }

pull_if_new() {
  local image="$1"
  local before after
  before=$(image_id "${image}")
  docker pull "${image}" --quiet > /dev/null 2>&1 || {
    log warn "Pull failed" image "${image}"
    return 1
  }
  after=$(image_id "${image}")
  [[ "${before}" != "${after}" ]]
}

verify_image() {
  local image="$1"
  if cosign verify \
       --certificate-identity "${CERT_IDENTITY}" \
       --certificate-oidc-issuer "${CERT_OIDC_ISSUER}" \
       "${image}" > /dev/null 2>&1; then
    return 0
  fi
  local msg="Signature verification FAILED for ${image}"
  log error "${msg}" signer "${CERT_IDENTITY}"
  set_unhealthy "${msg}"
  return 1
}

# ---------------------------------------------------------------------------
# Startup — launch health server then initialise health state
# ---------------------------------------------------------------------------

python3 /health_server.py &
HEALTH_SERVER_PID=$!

set_healthy

log info "Deployer starting" project "${COMPOSE_PROJECT_NAME}" poll_interval "${POLL_INTERVAL}s"
log info "Signature policy" identity "${CERT_IDENTITY}"

# Authenticate with GHCR using the PAT already present in the environment.
# docker pull delegates auth to the calling client (not the daemon), so the
# CLI inside this container needs its own credentials.
log info "Authenticating with GHCR"
echo "${GITHUB_TOKEN}" | docker login ghcr.io -u "${GITHUB_ORG}" --password-stdin \
  || log warn "GHCR login failed — pulls of private images will fail"

# ---------------------------------------------------------------------------
# Graceful shutdown
# ---------------------------------------------------------------------------

shutdown() {
  log info "Shutting down"
  kill "${HEALTH_SERVER_PID}" 2>/dev/null || true
  exit 0
}
trap shutdown SIGTERM SIGINT

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

while true; do
  # -------------------------------------------------------------------------
  # 1. Self-update
  # -------------------------------------------------------------------------
  if pull_if_new "${DEPLOYER_IMAGE}"; then
    if verify_image "${DEPLOYER_IMAGE}"; then
      log info "New deployer image verified — self-updating"
      ${COMPOSE} up -d --no-deps deployer
      exit 0
    fi
  fi

  # -------------------------------------------------------------------------
  # 2. Controller update
  # -------------------------------------------------------------------------
  if pull_if_new "${CONTROLLER_IMAGE}"; then
    if verify_image "${CONTROLLER_IMAGE}"; then
      log info "New controller image verified — updating controller"
      if ${COMPOSE} up -d --no-deps controller; then
        log info "Controller updated successfully"
      else
        set_unhealthy "docker compose up -d controller failed"
      fi
    fi
  fi

  # -------------------------------------------------------------------------
  # 3. Runner image — verify remote signature before pulling
  # -------------------------------------------------------------------------
  if verify_image "${RUNNER_IMAGE}"; then
    docker pull "${RUNNER_IMAGE}" --quiet > /dev/null 2>&1 || true
  fi

  # Successful cycle — mark healthy (clears any transient errors from prior cycles)
  set_healthy

  sleep "${POLL_INTERVAL}"
done
