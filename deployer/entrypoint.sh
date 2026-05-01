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
GITHUB_REPO="${GITHUB_REPO:-infra-runner}"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:?COMPOSE_PROJECT_NAME is required}"
POLL_INTERVAL="${POLL_INTERVAL:-60}"
HEALTH_FILE="${HEALTH_FILE:-/tmp/health}"
HEALTH_PORT="${HEALTH_PORT:-8080}"

CONTROLLER_IMAGE="ghcr.io/${GITHUB_ORG}/infra-runner-controller:latest"
RUNNER_IMAGE="ghcr.io/${GITHUB_ORG}/infra-runner:latest"
DEPLOYER_IMAGE="ghcr.io/${GITHUB_ORG}/uye-deployer:latest"

CERT_IDENTITY="https://github.com/${GITHUB_ORG}/${GITHUB_REPO}/.github/workflows/deploy.yml@refs/heads/main"
CERT_OIDC_ISSUER="https://token.actions.githubusercontent.com"

COMPOSE=(docker compose --project-name "${COMPOSE_PROJECT_NAME}" --project-directory /workspace)

LOG_SVC=deployer
# shellcheck source=scripts/logging.sh
source /scripts/logging.sh

# ---------------------------------------------------------------------------
# Authentication — GitHub App (preferred) or static PAT (backward compat)
# ---------------------------------------------------------------------------
# If GITHUB_TOKEN is already set in the environment, use it as-is and skip
# the App flow entirely (backward-compatible path).
# Otherwise the three GITHUB_APP_* vars must be present and the helper script
# generates a short-lived installation token at startup, refreshed every 55 min.

_USING_GITHUB_APP=false
TOKEN_ISSUED_AT=0

if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  : # static PAT provided — use as-is
else
  _USING_GITHUB_APP=true
  GITHUB_APP_ID="${GITHUB_APP_ID:?GITHUB_APP_ID is required (or set GITHUB_TOKEN directly)}"
  GITHUB_APP_INSTALLATION_ID="${GITHUB_APP_INSTALLATION_ID:?GITHUB_APP_INSTALLATION_ID is required}"
  GITHUB_APP_PRIVATE_KEY_PATH="${GITHUB_APP_PRIVATE_KEY_PATH:?GITHUB_APP_PRIVATE_KEY_PATH is required}"
  [[ -r "${GITHUB_APP_PRIVATE_KEY_PATH}" ]] \
    || { printf 'Private key not readable: %s\n' "${GITHUB_APP_PRIVATE_KEY_PATH}" >&2; exit 1; }
  # shellcheck source=scripts/github-app-token.sh
  source /scripts/github-app-token.sh
  GITHUB_TOKEN=""  # populated by acquire_github_token below
fi

# ---------------------------------------------------------------------------
# Health state
# ---------------------------------------------------------------------------

set_healthy() {
  printf '{"status":"ok","ts":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${HEALTH_FILE}.tmp" \
    && mv "${HEALTH_FILE}.tmp" "${HEALTH_FILE}"
}

set_unhealthy() {
  local reason="$1"
  local r="${reason//\\/\\\\}"; r="${r//\"/\\\"}"
  printf '{"status":"unhealthy","reason":"%s","ts":"%s"}\n' \
    "${r}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${HEALTH_FILE}.tmp" \
    && mv "${HEALTH_FILE}.tmp" "${HEALTH_FILE}"
  log warn "Health → unhealthy" reason "${reason}"
}

# ---------------------------------------------------------------------------
# Auth helpers
# ---------------------------------------------------------------------------

ghcr_login() {
  printf '%s' "${GITHUB_TOKEN}" \
    | docker login ghcr.io -u "${GITHUB_ORG}" --password-stdin \
    || log warn "GHCR login failed — pulls of private images will fail"
}

acquire_github_token() {
  local tok
  tok=$(generate_installation_token) || {
    log error "Failed to acquire GitHub App installation token"
    return 1
  }
  GITHUB_TOKEN="${tok}"
  TOKEN_ISSUED_AT=$(date +%s)
  log info "GitHub App installation token acquired"
}

# Proactively refresh the installation token at 55 min (before the 1-hour expiry).
maybe_refresh_github_token() {
  [[ "${_USING_GITHUB_APP}" == "true" ]] || return 0
  local now elapsed
  now=$(date +%s)
  elapsed=$(( now - TOKEN_ISSUED_AT ))
  if (( elapsed >= 3300 )); then
    log info "GitHub App token nearing expiry; refreshing" elapsed_s "${elapsed}"
    acquire_github_token
    ghcr_login
  fi
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

# Authenticate with GHCR. On the App path a fresh installation token is minted
# first; on the PAT path the token already present in the environment is used.
# docker pull delegates auth to the calling client (not the daemon), so the
# CLI inside this container needs its own credentials.
if [[ "${_USING_GITHUB_APP}" == "true" ]]; then
  acquire_github_token
fi
log info "Authenticating with GHCR"
ghcr_login

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
  maybe_refresh_github_token

  # -------------------------------------------------------------------------
  # 1. Self-update
  # -------------------------------------------------------------------------
  if pull_if_new "${DEPLOYER_IMAGE}"; then
    if verify_image "${DEPLOYER_IMAGE}"; then
      log info "New deployer image verified — self-updating"
      "${COMPOSE[@]}" up -d --no-deps deployer
      exit 0
    fi
  fi

  # -------------------------------------------------------------------------
  # 2. Controller update
  # -------------------------------------------------------------------------
  if pull_if_new "${CONTROLLER_IMAGE}"; then
    if verify_image "${CONTROLLER_IMAGE}"; then
      log info "New controller image verified — updating controller"
      if "${COMPOSE[@]}" up -d --no-deps controller; then
        log info "Controller updated successfully"
      else
        set_unhealthy "docker compose up -d controller failed"
      fi
    fi
  fi

  # -------------------------------------------------------------------------
  # 3. Runner image — verify remote signature before pulling
  # -------------------------------------------------------------------------
  _runner_pull_ok=true
  if verify_image "${RUNNER_IMAGE}"; then
    if ! docker pull "${RUNNER_IMAGE}" --quiet > /dev/null 2>&1; then
      log warn "Runner image pull failed — controller will use cached image" image "${RUNNER_IMAGE}"
      set_unhealthy "Runner image pull failed: ${RUNNER_IMAGE}"
      _runner_pull_ok=false
    fi
  fi

  # Successful cycle — mark healthy (clears any transient errors from prior cycles).
  # Skip if runner pull failed so the unhealthy state is not immediately overwritten.
  if [[ "${_runner_pull_ok}" == true ]]; then
    set_healthy
  fi

  sleep "${POLL_INTERVAL}"
done
