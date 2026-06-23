#!/bin/bash
# GitOps pull-based deployer.
#
# Polls GHCR for new image digests. When a new image is detected it verifies
# the cosign signature (keyless, anchored to the CI workflow OIDC identity)
# before applying the change via docker compose.
#
# Update order:
#   1. deployer itself  (verify → pull → compose up -d in background → start replacement → exit)
#   2. controller       (verify → docker compose up -d controller)
#   3. runner image     (verify remote sig → pull)
#   4. plugins          (for each *.plugin in PLUGINS_DIR: verify → pull → compose up → hooks)
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

PLUGINS_DIR="${PLUGINS_DIR:-/plugins/}"

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
  local auth_b64
  auth_b64=$(printf 'x-access-token:%s' "${GITHUB_TOKEN}" | base64 -w0)
  printf '{"auths":{"ghcr.io":{"auth":"%s"}}}\n' "${auth_b64}" > /root/.docker/config.json \
    || log warn "GHCR auth setup failed — pulls of private images will fail"
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

# verify_image IMAGE [CERT_IDENTITY]
# Uses CERT_IDENTITY from the second argument, or falls back to $CERT_IDENTITY.
verify_image() {
  local image="$1"
  local cert_identity="${2:-${CERT_IDENTITY}}"
  if cosign verify \
       --certificate-identity "${cert_identity}" \
       --certificate-oidc-issuer "${CERT_OIDC_ISSUER}" \
       "${image}" > /dev/null 2>&1; then
    return 0
  fi
  local msg="Signature verification FAILED for ${image}"
  log error "${msg}" signer "${cert_identity}"
  set_unhealthy "${msg}"
  return 1
}

# ---------------------------------------------------------------------------
# Plugin system — generic drop-in deployer
# ---------------------------------------------------------------------------
# Scans PLUGINS_DIR for *.plugin descriptor files and applies image updates.
# Each descriptor is shell-sourceable. See deployer/PLUGINS.md for the format.

_run_plugin_hooks() {
  local descriptor="$1" compose_dir="$2" updated="$3"
  local i=0
  while true; do
    local script run blocking
    script=$(  set -a; source "${descriptor}" 2>/dev/null; eval "printf '%s' \"\${PLUGIN_POST_DEPLOY_${i}_SCRIPT:-}\"")
    [[ -n "${script}" ]] || break
    run=$(     set -a; source "${descriptor}" 2>/dev/null; eval "printf '%s' \"\${PLUGIN_POST_DEPLOY_${i}_RUN:-on_update}\"")
    blocking=$(set -a; source "${descriptor}" 2>/dev/null; eval "printf '%s' \"\${PLUGIN_POST_DEPLOY_${i}_BLOCKING:-true}\"")
    local should_run=false
    [[ "${run}" == "always" ]] && should_run=true
    [[ "${run}" == "on_update" && "${updated}" == "true" ]] && should_run=true
    if [[ "${should_run}" == "true" ]]; then
      local abs="${compose_dir}/${script}"
      log info "Running post-deploy hook" script "${abs}" run "${run}"
      if bash "${abs}"; then
        log info "Post-deploy hook succeeded" script "${abs}"
      elif [[ "${blocking}" == "true" ]]; then
        set_unhealthy "Post-deploy hook failed: ${abs}"
      else
        log warn "Post-deploy hook failed (non-blocking)" script "${abs}"
      fi
    fi
    (( i++ ))
  done
}

run_plugins() {
  [[ -d "${PLUGINS_DIR}" ]] || return 0
  local found
  found=$(find "${PLUGINS_DIR}" -maxdepth 1 -name '*.plugin' 2>/dev/null | head -1)
  [[ -n "${found}" ]] || return 0

  for descriptor in "${PLUGINS_DIR}"/*.plugin; do
    [[ -f "${descriptor}" ]] || continue

    local vars
    vars=$(
      unset PLUGIN_NAME PLUGIN_IMAGE PLUGIN_CERT_IDENTITY \
            PLUGIN_COMPOSE_PROJECT PLUGIN_COMPOSE_DIR PLUGIN_COMPOSE_SERVICE
      # shellcheck source=/dev/null
      source "${descriptor}" 2>/dev/null || { echo LOAD_FAILED; exit 1; }
      printf '%s\n' \
        "PLUGIN_NAME=${PLUGIN_NAME:-}" \
        "PLUGIN_IMAGE=${PLUGIN_IMAGE:-}" \
        "PLUGIN_CERT_IDENTITY=${PLUGIN_CERT_IDENTITY:-}" \
        "PLUGIN_COMPOSE_PROJECT=${PLUGIN_COMPOSE_PROJECT:-}" \
        "PLUGIN_COMPOSE_DIR=${PLUGIN_COMPOSE_DIR:-}" \
        "PLUGIN_COMPOSE_SERVICE=${PLUGIN_COMPOSE_SERVICE:-}"
    ) || { log warn "Plugin descriptor failed to load" file "${descriptor}"; continue; }

    local PLUGIN_NAME PLUGIN_IMAGE PLUGIN_CERT_IDENTITY \
          PLUGIN_COMPOSE_PROJECT PLUGIN_COMPOSE_DIR PLUGIN_COMPOSE_SERVICE
    while IFS='=' read -r k v; do printf -v "$k" '%s' "$v"; done <<< "${vars}"

    if [[ -z "${PLUGIN_NAME}" || -z "${PLUGIN_IMAGE}" || -z "${PLUGIN_CERT_IDENTITY}" || \
          -z "${PLUGIN_COMPOSE_PROJECT}" || -z "${PLUGIN_COMPOSE_DIR}" || \
          -z "${PLUGIN_COMPOSE_SERVICE}" ]]; then
      log warn "Plugin descriptor missing required fields — skipping" file "${descriptor}"
      continue
    fi

    log info "Checking plugin" plugin "${PLUGIN_NAME}" image "${PLUGIN_IMAGE}"
    local updated=false
    if pull_if_new "${PLUGIN_IMAGE}"; then
      if verify_image "${PLUGIN_IMAGE}" "${PLUGIN_CERT_IDENTITY}"; then
        log info "New plugin image verified — updating service" \
          plugin "${PLUGIN_NAME}" service "${PLUGIN_COMPOSE_SERVICE}"
        if docker compose \
             --project-name "${PLUGIN_COMPOSE_PROJECT}" \
             --project-directory "${PLUGIN_COMPOSE_DIR}" \
             up -d --no-deps "${PLUGIN_COMPOSE_SERVICE}"; then
          log info "Plugin service updated" plugin "${PLUGIN_NAME}"
          updated=true
        else
          set_unhealthy "docker compose up failed for plugin ${PLUGIN_NAME}"
        fi
      fi
    fi

    _run_plugin_hooks "${descriptor}" "${PLUGIN_COMPOSE_DIR}" "${updated}"
  done
}

# ---------------------------------------------------------------------------
# Startup — launch health server then initialise health state
# ---------------------------------------------------------------------------

python3 /health_server.py &
HEALTH_SERVER_PID=$!

set_healthy

log info "Deployer starting" project "${COMPOSE_PROJECT_NAME}" poll_interval "${POLL_INTERVAL}s"
log info "Signature policy" identity "${CERT_IDENTITY}"

# Authenticate with GHCR. On the PAT path the token in the environment is used
# directly. On the App path, GHCR login is skipped — App installation tokens
# cannot access GHCR regardless of permissions; packages must be public.
if [[ "${_USING_GITHUB_APP}" == "true" ]]; then
  acquire_github_token
else
  log info "Authenticating with GHCR"
  ghcr_login
fi

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
      # Compose creates the replacement container before stopping this one, then
      # sends docker-stop (SIGTERM → 10 s timeout → SIGKILL) to us. SIGKILL kills
      # PID 1 and all children — including the compose subprocess — before compose
      # can issue the start command. Run compose in the background and race it:
      # poll until the new container appears in "created" state, start it ourselves,
      # then wait for the inevitable SIGKILL.
      "${COMPOSE[@]}" up -d --no-deps deployer &
      _new_id=""
      for _ in $(seq 1 20); do
        sleep 0.5
        _new_id=$(docker ps -aq \
          --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}" \
          --filter "label=com.docker.compose.service=deployer" \
          --filter "ancestor=$(image_id "${DEPLOYER_IMAGE}")" \
          --filter "status=created" 2>/dev/null | head -1)
        [[ -n "${_new_id}" ]] && { docker start "${_new_id}" 2>/dev/null; break; }
      done
      [[ -z "${_new_id}" ]] \
        && log warn "Self-update: replacement container not found within 10 s — may need manual start"
      wait 2>/dev/null || true
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

  # -------------------------------------------------------------------------
  # 4. Plugin services — generic drop-in deployer
  # -------------------------------------------------------------------------
  run_plugins

  # Successful cycle — mark healthy (clears any transient errors from prior cycles).
  # Skip if runner pull failed so the unhealthy state is not immediately overwritten.
  if [[ "${_runner_pull_ok}" == true ]]; then
    set_healthy
  fi

  sleep "${POLL_INTERVAL}"
done
