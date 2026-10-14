#!/bin/bash
# Ephemeral runner pool manager.
#
# Every CONTROLLER_POLL_INTERVAL seconds it reconciles the pool:
#   1. remove exited/dead runner containers and orphaned per-job networks
#   2. ask GitHub which managed runners are busy
#   3. spawn runners until DESIRED_IDLE are idle, never exceeding MAX_RUNNERS in total
#
# Robustness rules (see AGENTS.md → controller walkthrough):
#   - The main loop never exits on a transient error (GitHub API, socket proxy restart):
#     a failed cycle is logged and retried. A crash would trigger a restart, and the
#     controller is the one component that can kill in-flight jobs.
#   - Startup ADOPTS running runners instead of removing them, so a controller restart
#     or image update does not abort jobs that are already executing.
#   - Shutdown removes only IDLE runners by default (SHUTDOWN_CLEANUP=idle).
set -euo pipefail

GITHUB_ORG="${GITHUB_ORG:?GITHUB_ORG is required}"
RUNNER_IMAGE="${RUNNER_IMAGE:?RUNNER_IMAGE is required}"

RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,x64}"
DESIRED_IDLE="${DESIRED_IDLE:-2}"
# Hard cap on runner containers (idle + busy). Defaults to DESIRED_IDLE, i.e. the
# pre-existing behaviour of a fixed-size pool; raise it to keep idle runners warm
# while jobs are executing.
MAX_RUNNERS="${MAX_RUNNERS:-${DESIRED_IDLE}}"
RUNNER_MEMORY="${RUNNER_MEMORY:-4g}"
RUNNER_CPUS="${RUNNER_CPUS:-2}"
RUNNER_PIDS_LIMIT="${RUNNER_PIDS_LIMIT:-4096}"
RUNNER_KANIKO_SIZE="${RUNNER_KANIKO_SIZE:-5g}"
# `-` not `:-`: unset → default profile, explicitly empty → AppArmor disabled (as documented).
RUNNER_APPARMOR_PROFILE="${RUNNER_APPARMOR_PROFILE-infra-runner}"
RUNNER_SECCOMP_HOST_PATH="${RUNNER_SECCOMP_HOST_PATH:-}"
# Per-job /24 networks are carved from <prefix>.0.0/16 with an EXPLICIT --subnet, so only
# runner networks land in the range that setup-egress-policy.sh restricts (Docker's
# default-address-pools would also hand it to every other network on the host).
RUNNER_SUBNET_PREFIX="${RUNNER_SUBNET_PREFIX:-10.89}"
# jit   — single-use JIT config (default). Nothing reusable ever enters the runner.
# token — legacy registration token (reusable for 1 h by anyone who reads it).
RUNNER_REGISTRATION_MODE="${RUNNER_REGISTRATION_MODE:-jit}"
RUNNER_GROUP_ID="${RUNNER_GROUP_ID:-1}"
CONTROLLER_POLL_INTERVAL="${CONTROLLER_POLL_INTERVAL:-15}"
# idle — remove idle runners on shutdown, leave busy ones to finish (default)
# all  — remove every runner (interrupts running jobs)
# none — leave everything; the next controller adopts it
SHUTDOWN_CLEANUP="${SHUTDOWN_CLEANUP:-idle}"
HEARTBEAT_FILE="${HEARTBEAT_FILE:-/tmp/heartbeat}"
SCRIPTS_DIR="${SCRIPTS_DIR:-/scripts}"
GITHUB_API="${GITHUB_API:-https://api.github.com}"

LOG_SVC=controller
# shellcheck source=scripts/logging.sh
source "${SCRIPTS_DIR}/logging.sh"

die() { log error "$1"; exit 1; }

for _v in DESIRED_IDLE MAX_RUNNERS RUNNER_PIDS_LIMIT RUNNER_GROUP_ID CONTROLLER_POLL_INTERVAL; do
  # Reject leading zeroes as well: Bash arithmetic treats values such as 08 as octal.
  [[ "${!_v}" =~ ^(0|[1-9][0-9]{0,12})$ ]] \
    || die "${_v} must be a non-negative decimal integer (got '${!_v}')"
done
(( DESIRED_IDLE <= 1000 )) || die "DESIRED_IDLE must be at most 1000"
(( MAX_RUNNERS <= 1000 )) || die "MAX_RUNNERS must be at most 1000"
(( RUNNER_PIDS_LIMIT >= 1 && RUNNER_PIDS_LIMIT <= 1048576 )) \
  || die "RUNNER_PIDS_LIMIT must be between 1 and 1048576"
(( RUNNER_GROUP_ID >= 1 )) || die "RUNNER_GROUP_ID must be positive"
(( CONTROLLER_POLL_INTERVAL >= 1 && CONTROLLER_POLL_INTERVAL <= 240 )) \
  || die "CONTROLLER_POLL_INTERVAL must be between 1 and 240 (heartbeat expires after 300s)"
case "${RUNNER_REGISTRATION_MODE}" in jit|token) ;; *) die "RUNNER_REGISTRATION_MODE must be jit or token";; esac
case "${SHUTDOWN_CLEANUP}" in idle|all|none) ;; *) die "SHUTDOWN_CLEANUP must be idle, all or none";; esac
[[ "${RUNNER_SUBNET_PREFIX}" =~ ^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$ ]] \
  || die "RUNNER_SUBNET_PREFIX must look like 10.89"
(( BASH_REMATCH[1] >= 1 && BASH_REMATCH[1] <= 223 && BASH_REMATCH[2] <= 255 )) \
  || die "RUNNER_SUBNET_PREFIX octets must form a valid IPv4 network prefix"

# ---------------------------------------------------------------------------
# Authentication — GitHub App (preferred) or static PAT (backward compat)
# ---------------------------------------------------------------------------

_USING_GITHUB_APP=false
TOKEN_ISSUED_AT=0

if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  : # static PAT provided — use as-is
else
  _USING_GITHUB_APP=true
  GITHUB_APP_ID="${GITHUB_APP_ID:?GITHUB_APP_ID is required (or set GITHUB_TOKEN directly)}"
  GITHUB_APP_INSTALLATION_ID="${GITHUB_APP_INSTALLATION_ID:?GITHUB_APP_INSTALLATION_ID is required}"
  GITHUB_APP_PRIVATE_KEY_PATH="${GITHUB_APP_PRIVATE_KEY_PATH:?GITHUB_APP_PRIVATE_KEY_PATH is required}"
  [[ -r "${GITHUB_APP_PRIVATE_KEY_PATH}" ]] || die "Private key not readable: ${GITHUB_APP_PRIVATE_KEY_PATH}"
  # shellcheck source=scripts/github-app-token.sh
  source "${SCRIPTS_DIR}/github-app-token.sh"
  GITHUB_TOKEN=""  # populated by acquire_github_token
fi

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

# Refresh at 55 min. On failure the current token is kept (still valid for ~5 min)
# and the refresh is retried on the next cycle.
maybe_refresh_github_token() {
  [[ "${_USING_GITHUB_APP}" == "true" ]] || return 0
  local elapsed=$(( $(date +%s) - TOKEN_ISSUED_AT ))
  (( elapsed >= 3300 )) || return 0
  log info "GitHub App token nearing expiry; refreshing" elapsed_s "${elapsed}"
  acquire_github_token
}

# ---------------------------------------------------------------------------
# GitHub API
# ---------------------------------------------------------------------------

# gh_api METHOD PATH [JSON_BODY] [OK_STATUS]
# Prints the response body. Fails (and logs status + GitHub's message) on a non-2xx
# status, except OK_STATUS (e.g. 404 for an idempotent DELETE), which is treated as success.
gh_api() {
  local method="$1" path="$2" body="${3:-}" ok_status="${4:-}"
  local args=(-sS --max-time 30 -X "${method}"
    -H "Authorization: Bearer ${GITHUB_TOKEN}"
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28"
    -w $'\n%{http_code}')
  [[ -n "${body}" ]] && args+=(-H "Content-Type: application/json" --data "${body}")

  local out code
  out=$(curl "${args[@]}" "${GITHUB_API}${path}") || {
    log warn "GitHub API request failed" method "${method}" path "${path}"
    return 1
  }
  code="${out##*$'\n'}"
  out="${out%$'\n'*}"
  if [[ "${code}" != 2* && "${code}" != "${ok_status}" ]]; then
    log warn "GitHub API error" method "${method}" path "${path}" status "${code}" \
      message "$(jq -r '.message // empty' <<< "${out}" 2>/dev/null || true)"
    return 1
  fi
  printf '%s' "${out}"
}

# Populates _GH_BUSY[name]=true|false and _GH_ID[name]=id for this controller's runners
# (name prefix runner-job-). Must run in the current shell (not $(...)) to keep the maps.
declare -gA _GH_BUSY=() _GH_ID=()
load_org_runners() {
  _GH_BUSY=(); _GH_ID=()
  local page=1 body parsed records n name busy id
  while true; do
    body=$(gh_api GET "/orgs/${GITHUB_ORG}/actions/runners?per_page=100&page=${page}") || return 1
    # Validate the entire page before using any of it. A 2xx response with malformed or
    # incomplete JSON must not make busy runners appear idle.
    parsed=$(jq -ec '
      if (.runners | type) != "array" then error("missing runners array") else .runners end
      | if any(.[]; (.name | type) != "string" or (.busy | type) != "boolean" or (.id | type) != "number")
        then error("invalid runner record") else . end
      | {count: length, runners: [.[] | select(.name | startswith("runner-job-"))]}
    ' <<< "${body}") || {
      log warn "Invalid GitHub runner list response" page "${page}"
      return 1
    }
    records=$(jq -r '.runners[] | "\(.name)|\(.busy)|\(.id)"' <<< "${parsed}") || return 1
    while IFS='|' read -r name busy id; do
      [[ -n "${name}" ]] || continue
      _GH_BUSY["${name}"]="${busy}"
      _GH_ID["${name}"]="${id}"
    done <<< "${records}"
    n=$(jq -r '.count' <<< "${parsed}") || return 1
    (( n < 100 )) && break
    page=$(( page + 1 ))
    if (( page > 1000 )); then
      log warn "GitHub runner list exceeded 1000 pages"
      return 1
    fi
  done
  return 0
}

# Idempotent: 404 (already removed — e.g. ephemeral runner after its job) is fine.
deregister_runner() {
  local gh_id="$1"
  [[ -n "${gh_id}" ]] || return 0
  gh_api DELETE "/orgs/${GITHUB_ORG}/actions/runners/${gh_id}" "" 404 > /dev/null
}

fetch_registration_token() {
  local resp
  resp=$(gh_api POST "/orgs/${GITHUB_ORG}/actions/runners/registration-token") || return 1
  jq -r '.token // empty' <<< "${resp}"
}

# ---------------------------------------------------------------------------
# Docker helpers
# ---------------------------------------------------------------------------

RUNNER_FILTER=(--filter "label=runner-managed=true" --filter "label=runner-role=runner")

# cleanup_job JOB_ID [GH_RUNNER_ID] [FORCE_LOCAL]
cleanup_job() {
  local job_id="$1" gh_id="${2:-}" force_local="${3:-false}"
  local failed=0
  # Keep the stopped container (and its runner-gh-id label) until GitHub accepts
  # deregistration. Otherwise a transient API failure loses the ID needed to retry.
  if ! deregister_runner "${gh_id}"; then
    log warn "Could not deregister runner" job_id "${job_id}" gh_id "${gh_id}"
    [[ "${force_local}" == true ]] || return 1
    failed=1
  fi
  if ! docker rm -f "runner-job-${job_id}" > /dev/null 2>&1; then
    log warn "Could not remove runner container" job_id "${job_id}"
    failed=1
  fi
  if ! docker network rm "runner-net-${job_id}" > /dev/null 2>&1; then
    log warn "Could not remove runner network" job_id "${job_id}"
    failed=1
  fi
  return "${failed}"
}

# Run cleanup_job for each "job_id|gh_id" line in parallel and wait for all of them.
# (Background jobs are started from THIS shell, not from a `| while` subshell, so
# `wait` really waits for them.)
cleanup_jobs_parallel() {
  local lines="$1" force_local="${2:-false}" job_id gh_id pids=() failed=0
  while IFS='|' read -r job_id gh_id; do
    [[ -n "${job_id}" ]] || continue
    cleanup_job "${job_id}" "${gh_id}" "${force_local}" &
    pids+=("$!")
  done <<< "${lines}"
  local p
  for p in "${pids[@]}"; do wait "${p}" || failed=1; done
  return "${failed}"
}

# Exited, dead, or never-started (created) runner containers.
cleanup_dead_runners() {
  local out job_id gh_id status todo=""
  out=$(docker ps -a "${RUNNER_FILTER[@]}" \
    --filter status=exited --filter status=dead --filter status=created \
    --format '{{.Label "runner-job-id"}}|{{.Label "runner-gh-id"}}|{{.Status}}') || return 1
  while IFS='|' read -r job_id gh_id status; do
    [[ -n "${job_id}" ]] || continue
    log info "Runner exited" job_id "${job_id}" status "${status}"
    todo+="${job_id}|${gh_id}"$'\n'
  done <<< "${out}"
  cleanup_jobs_parallel "${todo}"
}

# Per-job networks whose runner container no longer exists (e.g. controller killed
# between `network create` and `docker run`).
cleanup_orphan_networks() {
  local nets ctrs name job_id failed=0
  nets=$(docker network ls --filter "label=runner-managed=true" \
    --format '{{.Name}}|{{.Label "runner-job-id"}}') || return 1
  ctrs=$(docker ps -a "${RUNNER_FILTER[@]}" --format '{{.Label "runner-job-id"}}') || return 1
  while IFS='|' read -r name job_id; do
    [[ -n "${name}" ]] || continue
    if [[ -z "${job_id}" ]] || ! grep -qxF "${job_id}" <<< "${ctrs}"; then
      log info "Removing orphaned network" network "${name}"
      if ! docker network rm "${name}" > /dev/null 2>&1; then
        log warn "Could not remove orphaned network" network "${name}"
        failed=1
      fi
    fi
  done <<< "${nets}"
  return "${failed}"
}

# Prints "name|job_id|gh_id" per running runner container.
list_running_runners() {
  docker ps "${RUNNER_FILTER[@]}" --filter status=running \
    --format '{{.Names}}|{{.Label "runner-job-id"}}|{{.Label "runner-gh-id"}}'
}

# Remove running runners. MODE=idle keeps the ones GitHub reports as busy.
remove_running_runners() {
  local mode="$1" running name job_id gh_id todo=""
  running=$(list_running_runners) || return 1
  if [[ "${mode}" == idle ]] && ! load_org_runners; then
    log warn "Cannot determine busy runners — leaving all running runners in place"
    return 1
  fi
  while IFS='|' read -r name job_id gh_id; do
    [[ -n "${name}" ]] || continue
    if [[ "${mode}" == idle && "${_GH_BUSY[${name}]:-false}" == true ]]; then
      log info "Leaving busy runner to finish its job" job_id "${job_id}"
      continue
    fi
    [[ -n "${gh_id}" ]] || gh_id="${_GH_ID[${name}]:-}"
    log info "Removing runner" job_id "${job_id}" mode "${mode}"
    todo+="${job_id}|${gh_id}"$'\n'
  done <<< "${running}"
  local force_local=false
  [[ "${mode}" == all ]] && force_local=true
  cleanup_jobs_parallel "${todo}" "${force_local}"
}

# ---------------------------------------------------------------------------
# Spawning
# ---------------------------------------------------------------------------

# create_runner_network NAME JOB_ID — bridge network with an explicit /24 from
# RUNNER_SUBNET_PREFIX. The third octet is derived from the (random) job id and moved on
# when Docker reports an overlap with an existing network.
create_runner_network() {
  local net_name="$1" job_id="$2" attempt octet err
  local base=$(( 16#${job_id:0:2} ))
  for (( attempt = 0; attempt < 16; attempt++ )); do
    octet=$(( (base + attempt * 17) % 256 ))
    if err=$(docker network create --driver bridge --ipv6=false \
               --subnet "${RUNNER_SUBNET_PREFIX}.${octet}.0/24" \
               --label runner-managed=true --label "runner-job-id=${job_id}" \
               "${net_name}" 2>&1 > /dev/null); then
      return 0
    fi
    grep -qiE 'overlap|in use|already' <<< "${err}" || break
  done
  log error "Failed to create runner network" job_id "${job_id}" detail "${err}"
  return 1
}

# Labels as a JSON array: trimmed, empty entries dropped.
labels_json() {
  jq -nc --arg l "${RUNNER_LABELS}" \
    '$l | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))'
}

# Written without `set -e` reliance: it runs in a background subshell of reconcile(),
# which itself runs in an errexit-ignored context, so every failure is checked explicitly.
spawn_runner() {
  local job_id
  job_id=$(uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]' | cut -c1-10)
  local net_name="runner-net-${job_id}" runner_ctr="runner-job-${job_id}"

  log info "Spawning runner" job_id "${job_id}" mode "${RUNNER_REGISTRATION_MODE}"

  create_runner_network "${net_name}" "${job_id}" || return 1

  local reg_env=() gh_id=""
  if [[ "${RUNNER_REGISTRATION_MODE}" == jit ]]; then
    # JIT config: single-use, pre-registered, ephemeral by construction. Unlike a
    # registration token it cannot be replayed to register additional runners.
    local body resp jit
    body=$(jq -nc --arg name "${runner_ctr}" --argjson group "${RUNNER_GROUP_ID}" \
             --argjson labels "$(labels_json)" \
             '{name: $name, runner_group_id: $group, labels: $labels, work_folder: "_work"}')
    if ! resp=$(gh_api POST "/orgs/${GITHUB_ORG}/actions/runners/generate-jitconfig" "${body}"); then
      log error "Failed to generate JIT runner config" job_id "${job_id}"
      cleanup_job "${job_id}"
      return 1
    fi
    # GitHub registers the runner before returning this response. Require the
    # matching name and ID so cleanup has the correct runner to deregister.
    if ! jq -e --arg name "${runner_ctr}" '
      (.runner.name == $name) and
      (.runner.id | type == "number") and
      (.runner.id > 0) and
      (.runner.id == (.runner.id | floor)) and
      (.encoded_jit_config | type == "string") and
      (.encoded_jit_config | length > 0)
    ' <<< "${resp}" > /dev/null 2>&1; then
      # A partial response may still contain a usable ID. Never delete an ID
      # whose name does not match the one requested by this spawn.
      gh_id=$(jq -r --arg name "${runner_ctr}" \
        'select(.runner.name == $name) | .runner.id | numbers | select(. > 0 and . == floor)' \
        <<< "${resp}" 2>/dev/null) || gh_id=""
      if [[ -z "${gh_id}" ]]; then
        # The registration may already exist even if its response was partial.
        # Look up only the exact random name generated for this spawn.
        if load_org_runners; then
          gh_id="${_GH_ID[${runner_ctr}]:-}"
        fi
      fi
      log error "Invalid JIT runner response" job_id "${job_id}"
      [[ -n "${gh_id}" ]] || log warn "Cannot identify malformed JIT registration for deregistration" job_id "${job_id}"
      cleanup_job "${job_id}" "${gh_id}"
      return 1
    fi
    jit=$(jq -r '.encoded_jit_config' <<< "${resp}")
    gh_id=$(jq -r '.runner.id' <<< "${resp}")
    reg_env=(-e "RUNNER_JITCONFIG=${jit}")
  else
    local reg_token
    reg_token=$(fetch_registration_token) || reg_token=""
    if [[ -z "${reg_token}" ]]; then
      log error "Failed to obtain registration token" job_id "${job_id}"
      cleanup_job "${job_id}"
      return 1
    fi
    reg_env=(-e "RUNNER_REGISTRATION_TOKEN=${reg_token}"
             -e "GITHUB_ORG=${GITHUB_ORG}"
             -e "RUNNER_NAME=${runner_ctr}"
             -e "RUNNER_LABELS=${RUNNER_LABELS}")
  fi

  local security_opts=()
  [[ -n "${RUNNER_SECCOMP_HOST_PATH}" ]] && security_opts+=(--security-opt "seccomp=${RUNNER_SECCOMP_HOST_PATH}")
  [[ -n "${RUNNER_APPARMOR_PROFILE}" ]] && security_opts+=(--security-opt "apparmor=${RUNNER_APPARMOR_PROFILE}")

  # --pull never: only run an image the deployer has already pulled after verifying
  # its signature; never let `docker run` fetch an unverified :latest on its own.
  if ! docker run -d --pull never \
       --name "${runner_ctr}" \
       --network "${net_name}" \
       --memory="${RUNNER_MEMORY}" \
       --cpus="${RUNNER_CPUS}" \
       --pids-limit="${RUNNER_PIDS_LIMIT}" \
       --log-driver json-file --log-opt max-size=10m --log-opt max-file=3 \
       --cap-add CHOWN \
       --cap-add DAC_OVERRIDE \
       --cap-add FOWNER \
       --cap-add SETUID \
       --cap-add SETGID \
       --cap-add SYS_PTRACE \
       --cap-add SYS_ADMIN \
       "${security_opts[@]}" \
       --label runner-managed=true \
       --label "runner-job-id=${job_id}" \
       --label "runner-gh-id=${gh_id}" \
       --label runner-role=runner \
       --tmpfs /tmp:rw,nosuid,size=1g \
       --tmpfs /root:rw,nosuid,size=512m \
       --tmpfs /kaniko:rw,nosuid,size="${RUNNER_KANIKO_SIZE}" \
       --device /dev/fuse \
       "${reg_env[@]}" \
       -e RUNNER_ALLOW_RUNASROOT=1 \
       "${RUNNER_IMAGE}" > /dev/null; then
    log error "docker run failed for runner" job_id "${job_id}"
    cleanup_job "${job_id}" "${gh_id}"
    return 1
  fi

  local running
  if ! running=$(docker inspect "${runner_ctr}" --format '{{.State.Running}}' 2>&1); then
    # Docker may have started the container despite an inspect/API error. Leave it
    # for the next reconcile rather than interrupt a job that could be running.
    log warn "Cannot confirm runner startup" job_id "${job_id}" detail "${running}"
    return 1
  fi
  if [[ "${running}" != true ]]; then
    log error "Runner exited immediately after startup" job_id "${job_id}" state "${running}"
    cleanup_job "${job_id}" "${gh_id}"
    return 1
  fi

  log info "Runner is live" job_id "${job_id}"
}

# ---------------------------------------------------------------------------
# Reconcile loop
# ---------------------------------------------------------------------------

# Spawn backoff: consecutive cycles with a failed spawn delay the next attempt
# (15 s, 30 s, 60 s … capped at 300 s) instead of hammering the GitHub API.
_spawn_failures=0
_next_spawn_at=0
_image_missing_logged=false

# Called as `reconcile || …`, so errexit is OFF in here: check every step explicitly.
reconcile() {
  maybe_refresh_github_token \
    || log warn "Token refresh failed — keeping current token, retrying next cycle"

  cleanup_dead_runners || { log warn "Could not list exited runners"; return 1; }
  cleanup_orphan_networks || { log warn "Could not clean orphaned networks"; return 1; }

  local running
  running=$(list_running_runners) || { log warn "Could not list running runners"; return 1; }

  load_org_runners || { log warn "Could not query runner busy state"; return 1; }
  local total=0 idle=0 name job_id gh_id
  while IFS='|' read -r name job_id gh_id; do
    [[ -n "${name}" ]] || continue
    total=$(( total + 1 ))
    # A runner not (yet) listed by GitHub is still registering → counts as idle.
    [[ "${_GH_BUSY[${name}]:-false}" == true ]] || idle=$(( idle + 1 ))
  done <<< "${running}"
  local needed=$(( DESIRED_IDLE - idle ))
  local room=$(( MAX_RUNNERS - total ))
  (( room < needed )) && needed=${room}
  (( needed > 0 )) || return 0

  if ! docker image inspect "${RUNNER_IMAGE}" > /dev/null 2>&1; then
    if [[ "${_image_missing_logged}" == false ]]; then
      log warn "Runner image not present locally — waiting for the deployer to pull a verified image" \
        image "${RUNNER_IMAGE}"
      _image_missing_logged=true
    fi
    return 1
  fi
  _image_missing_logged=false

  local now; now=$(date +%s)
  if (( now < _next_spawn_at )); then
    return 1
  fi

  log info "Spawning runners" total "${total}" idle "${idle}" desired_idle "${DESIRED_IDLE}" \
    max "${MAX_RUNNERS}" spawning "${needed}"
  local pids=() p failed=0 i
  for (( i = 0; i < needed; i++ )); do
    spawn_runner &
    pids+=("$!")
  done
  for p in "${pids[@]}"; do wait "${p}" || failed=$(( failed + 1 )); done

  if (( failed > 0 )); then
    (( _spawn_failures < 10 )) && _spawn_failures=$(( _spawn_failures + 1 ))
    local delay=$(( CONTROLLER_POLL_INTERVAL * (1 << (_spawn_failures - 1)) ))
    (( delay > 300 )) && delay=300
    _next_spawn_at=$(( now + delay ))
    log warn "Runner spawn failed — backing off" failed "${failed}" retry_in_s "${delay}"
    return 1
  fi
  _spawn_failures=0
  _next_spawn_at=0
  return 0
}

# `sleep` in the foreground would defer the SIGTERM trap until it returns (bash runs
# traps only between foreground commands) — long enough for Docker's SIGKILL.
interruptible_sleep() {
  sleep "$1" &
  wait "$!" || true
}

shutdown() {
  trap - SIGTERM SIGINT
  log info "Shutting down" cleanup "${SHUTDOWN_CLEANUP}"
  case "${SHUTDOWN_CLEANUP}" in
    idle|all) remove_running_runners "${SHUTDOWN_CLEANUP}" || true ;;
    none) ;;
  esac
  cleanup_dead_runners || true
  cleanup_orphan_networks || true
  exit 0
}

main() {
  trap shutdown SIGTERM SIGINT

  log info "Controller starting" image "${RUNNER_IMAGE}" desired_idle "${DESIRED_IDLE}" \
    max_runners "${MAX_RUNNERS}" registration "${RUNNER_REGISTRATION_MODE}"

  if [[ "${_USING_GITHUB_APP}" == "true" ]]; then
    until acquire_github_token; do
      log warn "Retrying GitHub App token acquisition in 30s"
      interruptible_sleep 30
    done
  else
    log info "Authenticating with GHCR"
    ghcr_login
  fi

  # Adopt running runners from a previous controller; clean up only dead leftovers.
  # (No `docker pull` here: the runner image is pulled by the deployer after cosign
  # verification — pulling it here would bypass that check.)
  log info "Cleaning up leftovers from previous run (running runners are adopted)"
  cleanup_dead_runners || log warn "Startup cleanup of exited runners failed"
  cleanup_orphan_networks || log warn "Startup cleanup of orphaned networks failed"

  while true; do
    if reconcile; then
      date +%s > "${HEARTBEAT_FILE}"
    else
      log warn "Reconcile cycle incomplete — retrying next cycle"
    fi
    interruptible_sleep "${CONTROLLER_POLL_INTERVAL}"
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
