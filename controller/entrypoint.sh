#!/bin/bash
set -euo pipefail

GITHUB_ORG="${GITHUB_ORG:?GITHUB_ORG is required}"
RUNNER_IMAGE="${RUNNER_IMAGE:?RUNNER_IMAGE is required}"

RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,x64}"
DESIRED_IDLE="${DESIRED_IDLE:-2}"
RUNNER_MEMORY="${RUNNER_MEMORY:-4g}"
RUNNER_CPUS="${RUNNER_CPUS:-2}"
RUNNER_KANIKO_SIZE="${RUNNER_KANIKO_SIZE:-5g}"
RUNNER_APPARMOR_PROFILE="${RUNNER_APPARMOR_PROFILE:-infra-runner}"
RUNNER_SECCOMP_HOST_PATH="${RUNNER_SECCOMP_HOST_PATH:-}"
CONTROLLER_POLL_INTERVAL="${CONTROLLER_POLL_INTERVAL:-15}"

LOG_SVC=controller
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
# Each spawn_runner subshell inherits GITHUB_TOKEN at fork time; the 5-minute
# buffer ensures in-flight spawns finish before the old token expires.
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
# Lifecycle helpers
# ---------------------------------------------------------------------------

fetch_registration_token() {
  curl -fsSL \
    -X POST \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/orgs/${GITHUB_ORG}/actions/runners/registration-token" \
    | jq -r '.token'
}

cleanup_job() {
  local job_id="$1"
  log info "Cleaning up job" job_id "${job_id}"
  docker rm -f "runner-job-${job_id}"  2>/dev/null || true
  docker network rm "runner-net-${job_id}" 2>/dev/null || true
}

cleanup_all_managed() {
  log info "Cleaning up all managed resources"
  docker ps -a \
    --filter "label=runner-managed=true" \
    --filter "label=runner-role=runner" \
    --format '{{.Label "runner-job-id"}}' \
    | while read -r job_id; do
        [[ -n "${job_id}" ]] && cleanup_job "${job_id}" &
      done
  wait
  docker network ls \
    --filter "label=runner-managed=true" \
    --format '{{.Name}}' \
    | while read -r net; do
        docker network rm "${net}" 2>/dev/null || true
      done
}

cleanup_exited_runners() {
  docker ps -a \
    --filter "label=runner-managed=true" \
    --filter "label=runner-role=runner" \
    --filter "status=exited" \
    --format '{{.Label "runner-job-id"}}' \
    | while read -r job_id; do
        [[ -z "${job_id}" ]] && continue
        local exit_code
        exit_code=$(docker inspect "runner-job-${job_id}" \
          --format '{{.State.ExitCode}}' 2>/dev/null || echo "?")
        log info "Runner exited" job_id "${job_id}" exit_code "${exit_code}"
        cleanup_job "${job_id}" &
      done
  wait
}

count_active_runners() {
  docker ps \
    --filter "label=runner-managed=true" \
    --filter "label=runner-role=runner" \
    --format '{{.ID}}' \
    | wc -l | tr -d ' '
}

spawn_runner() {
  local job_id
  job_id=$(uuidgen | tr -d '-' | head -c 10 | tr '[:upper:]' '[:lower:]')

  local net_name="runner-net-${job_id}"
  local runner_ctr="runner-job-${job_id}"

  _on_error() { cleanup_job "${job_id}"; }
  trap _on_error ERR

  log info "Spawning runner" job_id "${job_id}"

  docker network create \
    --driver bridge \
    --label runner-managed=true \
    --label "runner-job-id=${job_id}" \
    "${net_name}" > /dev/null

  local reg_token
  reg_token=$(fetch_registration_token)
  if [[ -z "${reg_token}" || "${reg_token}" == "null" ]]; then
    log error "Failed to obtain registration token" job_id "${job_id}"
    cleanup_job "${job_id}"
    trap - ERR
    return 1
  fi

  local seccomp_flag=()
  if [[ -n "${RUNNER_SECCOMP_HOST_PATH}" ]]; then
    seccomp_flag=(--security-opt "seccomp=${RUNNER_SECCOMP_HOST_PATH}")
  fi

  local apparmor_flag=()
  if [[ -n "${RUNNER_APPARMOR_PROFILE}" ]]; then
    apparmor_flag=(--security-opt "apparmor=${RUNNER_APPARMOR_PROFILE}")
  fi

  docker run -d \
    --name "${runner_ctr}" \
    --network "${net_name}" \
    --memory="${RUNNER_MEMORY}" \
    --cpus="${RUNNER_CPUS}" \
    "${seccomp_flag[@]}" \
    "${apparmor_flag[@]}" \
    --label runner-managed=true \
    --label "runner-job-id=${job_id}" \
    --label runner-role=runner \
    --tmpfs /tmp:rw,nosuid,size=1g \
    --tmpfs /root:rw,nosuid,size=512m \
    --tmpfs /kaniko:rw,nosuid,size="${RUNNER_KANIKO_SIZE}" \
    -e GITHUB_ORG="${GITHUB_ORG}" \
    -e RUNNER_REGISTRATION_TOKEN="${reg_token}" \
    -e RUNNER_NAME="${runner_ctr}" \
    -e RUNNER_LABELS="${RUNNER_LABELS}" \
    -e RUNNER_ALLOW_RUNASROOT=1 \
    "${RUNNER_IMAGE}" > /dev/null

  log info "Runner is live" job_id "${job_id}"
  trap - ERR
}

# ---------------------------------------------------------------------------
# Graceful shutdown
# ---------------------------------------------------------------------------

shutdown() {
  log info "Shutting down — cleaning up all managed runners"
  cleanup_all_managed
  exit 0
}
trap shutdown SIGTERM SIGINT

# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------

log info "Controller starting" image "${RUNNER_IMAGE}" desired_idle "${DESIRED_IDLE}"

if [[ "${_USING_GITHUB_APP}" == "true" ]]; then
  acquire_github_token
fi

if [[ "${_USING_GITHUB_APP}" == "false" ]]; then
  log info "Authenticating with GHCR"
  ghcr_login
fi

log info "Checking for orphaned resources from previous run"
cleanup_all_managed
log info "Pre-pulling runner image"
docker pull "${RUNNER_IMAGE}" > /dev/null \
  || log warn "Runner image pre-pull failed — will retry on next cycle" \
       image "${RUNNER_IMAGE}"

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

while true; do
  maybe_refresh_github_token

  cleanup_exited_runners

  active=$(count_active_runners)
  needed=$(( DESIRED_IDLE - active ))

  if (( needed > 0 )); then
    log info "Spawning runners" active "${active}" desired "${DESIRED_IDLE}" spawning "${needed}"
    for _ in $(seq 1 "${needed}"); do
      spawn_runner &
    done
    wait
  fi

  sleep "${CONTROLLER_POLL_INTERVAL}"
done
