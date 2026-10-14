#!/bin/bash
# GitOps pull-based deployer — level-triggered reconcile loop.
#
# Every POLL_INTERVAL seconds, for each managed image:
#   1. cosign-verify the remote :latest and take the digest cosign actually verified
#   2. pull exactly that digest (never an unverified tag) and point :verified and the
#      watched tag (usually :latest) at it — unverified images never land on the host
#   3. compare the image of the running container with :verified; if they differ, apply
#
#   deployer itself → external self-update helper (see below)
#   controller      → docker compose up -d --no-deps controller
#   runner          → steps 1–2 only (the controller spawns runners from :verified)
#   plugins         → per *.plugin descriptor: compose up of the plugin service + hooks
#
# Because desired state (":verified") and actual state (the running container's image)
# are re-read every cycle, a failed deploy is retried automatically and nothing is lost
# when the deployer restarts — there is no in-memory "pending" queue.
#
# Self-update note: a process INSIDE a container cannot watch `docker compose` finish
# recreating that same container — compose stops the old container (killing the compose
# process with it) before it has attached every network to the replacement. We therefore
# delegate the recreate to a short-lived sibling "helper" container that runs compose from
# outside our lifecycle.
#
# Health endpoint: GET http://<host>:HEALTH_PORT/health
#   200 {"status":"ok",...}
#   503 {"status":"starting"|"unhealthy"|"stale",...}
set -euo pipefail

die() { printf '{"level":"error","svc":"deployer","msg":"%s"}\n' "$1" >&2; exit 1; }

GITHUB_ORG="${GITHUB_ORG:?GITHUB_ORG is required}"
GITHUB_REPO="${GITHUB_REPO:-infra-runner}"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:?COMPOSE_PROJECT_NAME is required}"
# Absolute HOST path of this repo; needed by the self-update helper to resolve the
# project and any sibling plugin overlays. Validated at startup, not at self-update time.
COMPOSE_PROJECT_DIR="${COMPOSE_PROJECT_DIR:?COMPOSE_PROJECT_DIR is required (absolute host path of this repo)}"
[[ "${COMPOSE_PROJECT_DIR}" == /* ]] || die "COMPOSE_PROJECT_DIR must be an absolute path"
POLL_INTERVAL="${POLL_INTERVAL:-60}"
SELF_UPDATE_TIMEOUT="${SELF_UPDATE_TIMEOUT:-120}"
PLUGIN_HOOK_TIMEOUT="${PLUGIN_HOOK_TIMEOUT:-300}"
PRUNE_INTERVAL="${PRUNE_INTERVAL:-3600}"
HEALTH_FILE="${HEALTH_FILE:-/tmp/health}"
HEALTH_PORT="${HEALTH_PORT:-8080}"

validate_range() {
  local name="$1" min="$2" max="$3" value="${!1}"
  [[ "${value}" =~ ^[1-9][0-9]{0,5}$ ]] && (( value >= min && value <= max )) \
    || die "${name} must be a decimal integer between ${min} and ${max}"
}
validate_range POLL_INTERVAL 5 3600
validate_range SELF_UPDATE_TIMEOUT 3 3600
validate_range PLUGIN_HOOK_TIMEOUT 1 3600
validate_range PRUNE_INTERVAL 60 86400
# /health turns 503 "stale" when the loop has not written a result for this long.
HEALTH_MAX_AGE="${HEALTH_MAX_AGE:-$(( 3 * POLL_INTERVAL + SELF_UPDATE_TIMEOUT + PLUGIN_HOOK_TIMEOUT ))}"
validate_range HEALTH_MAX_AGE 1 86400
validate_range HEALTH_PORT 1 65535
export HEALTH_FILE HEALTH_PORT HEALTH_MAX_AGE
PLUGINS_DIR="${PLUGINS_DIR:-/plugins/}"
SCRIPTS_DIR="${SCRIPTS_DIR:-/scripts}"
HEALTH_SERVER="${HEALTH_SERVER:-/health_server.py}"
HELPER_NAME="${COMPOSE_PROJECT_NAME}-deployer-selfupdate"

CONTROLLER_REPO="ghcr.io/${GITHUB_ORG}/infra-runner-controller"
RUNNER_REPO="ghcr.io/${GITHUB_ORG}/infra-runner"
DEPLOYER_REPO="ghcr.io/${GITHUB_ORG}/uye-deployer"
VERIFIED_TAG=verified

CERT_IDENTITY="https://github.com/${GITHUB_ORG}/${GITHUB_REPO}/.github/workflows/deploy.yml@refs/heads/main"
CERT_OIDC_ISSUER="https://token.actions.githubusercontent.com"

# Pin infra-runner's own base compose files with container-absolute paths (the project dir
# is bind-mounted at /workspace) so the controller update is unaffected by COMPOSE_FILE,
# whose plugin-overlay entries (../infra-vault/...) don't resolve from /workspace.
COMPOSE=(docker compose --project-name "${COMPOSE_PROJECT_NAME}" --project-directory /workspace -f /workspace/docker-compose.yml)
[[ -f /workspace/docker-compose.override.yml ]] && COMPOSE+=(-f /workspace/docker-compose.override.yml)

LOG_SVC=deployer
# shellcheck source=scripts/logging.sh
source "${SCRIPTS_DIR}/logging.sh"

_ERR_FILE="$(mktemp)"

# Last few non-empty lines of a captured stderr file, flattened for a log field.
err_tail() { grep -v '^[[:space:]]*$' "${_ERR_FILE}" 2>/dev/null | tail -n 3 | tr '\n' ' ' | cut -c1-600; }

# ---------------------------------------------------------------------------
# Health state
# ---------------------------------------------------------------------------
# Reasons collected during the current cycle; the end-of-cycle write turns them into
# "unhealthy" (or "ok" if empty). set_unhealthy also writes immediately so a failure is
# visible while the rest of the cycle is still running.
_cycle_reasons=()

write_health() {
  local status="$1" reason="${2:-}"
  jq -nc --arg s "${status}" --arg r "${reason}" \
         --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson e "$(date +%s)" \
     '{status: $s, ts: $ts, epoch: $e} + (if $r == "" then {} else {reason: $r} end)' \
     > "${HEALTH_FILE}.tmp" && mv "${HEALTH_FILE}.tmp" "${HEALTH_FILE}"
}

set_unhealthy() {
  _cycle_reasons+=("$1")
  write_health unhealthy "$1" || true
  log warn "Health → unhealthy" reason "$1"
}

HEALTH_SERVER_PID=""
ensure_health_server() {
  if [[ -n "${HEALTH_SERVER_PID}" ]] && kill -0 "${HEALTH_SERVER_PID}" 2>/dev/null; then
    return 0
  fi
  [[ -n "${HEALTH_SERVER_PID}" ]] && log warn "Health server died — restarting"
  python3 "${HEALTH_SERVER}" &
  HEALTH_SERVER_PID=$!
}

# ---------------------------------------------------------------------------
# Registry auth
# ---------------------------------------------------------------------------
# Only a classic PAT (GITHUB_TOKEN) can authenticate to GHCR. GitHub App installation
# tokens cannot, so on the App path images are pulled anonymously (must be public) and
# the deployer needs no GitHub credential at all.
ghcr_login() {
  local auth_b64
  auth_b64=$(printf 'x-access-token:%s' "${GITHUB_TOKEN}" | base64 -w0)
  printf '{"auths":{"ghcr.io":{"auth":"%s"}}}\n' "${auth_b64}" > /root/.docker/config.json \
    || log warn "GHCR auth setup failed — pulls of private images will fail"
}

# ---------------------------------------------------------------------------
# Image helpers
#
# These functions return data through globals (_digest, _desired_id, _actual_id …)
# instead of stdout, because they call set_unhealthy: inside $(…) the recorded reason
# would be lost with the subshell and the end-of-cycle write would report "ok".
# ---------------------------------------------------------------------------

# split_ref REF → _repo, _tag (tag defaults to "latest"; digest refs are rejected)
split_ref() {
  local ref="$1" last="${1##*/}"
  [[ "${last}" != *@* ]] || return 1
  if [[ "${last}" == *:* ]]; then
    _repo="${ref%:*}"; _tag="${ref##*:}"
  else
    _repo="${ref}"; _tag=latest
  fi
}

# verify_remote REF IDENTITY → _digest (the manifest digest cosign verified)
verify_remote() {
  local ref="$1" identity="$2" out
  _digest=""
  if out=$(cosign verify \
             --certificate-identity "${identity}" \
             --certificate-oidc-issuer "${CERT_OIDC_ISSUER}" \
             "${ref}" 2> "${_ERR_FILE}"); then
    _digest=$(jq -r '[.[].critical.image."docker-manifest-digest"] | unique
                     | if length == 1 then .[0] else empty end' <<< "${out}" 2>/dev/null || true)
    if [[ "${_digest}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
      return 0
    fi
    log error "cosign output did not contain exactly one verified digest" image "${ref}"
    set_unhealthy "Could not determine verified digest for ${ref}"
    return 1
  fi

  local detail; detail=$(err_tail)
  if grep -qiE 'no matching signatures|no signatures found|none of the expected identities|expected identity|certificate identity' <<< "${detail}"; then
    log error "Signature verification FAILED" image "${ref}" signer "${identity}" detail "${detail}"
    set_unhealthy "Signature verification FAILED for ${ref}"
  else
    log error "Signature verification could not complete" image "${ref}" detail "${detail}"
    set_unhealthy "Signature verification error for ${ref} (registry or Sigstore unreachable?)"
  fi
  return 1
}

# ensure_verified_local REPO TAG DIGEST — pull REPO@DIGEST if needed and point
# REPO:verified and REPO:TAG at it.
ensure_verified_local() {
  local repo="$1" tag="$2" digest="$3"
  local ref="${repo}@${digest}"
  if ! docker image inspect "${ref}" > /dev/null 2>&1; then
    log info "Pulling verified image" image "${ref}"
    if ! docker pull --quiet "${ref}" > /dev/null 2> "${_ERR_FILE}"; then
      log error "Pull of verified digest failed" image "${ref}" detail "$(err_tail)"
      set_unhealthy "Pull failed: ${ref}"
      return 1
    fi
  fi
  if ! docker tag "${ref}" "${repo}:${VERIFIED_TAG}" || ! docker tag "${ref}" "${repo}:${tag}"; then
    set_unhealthy "Tagging failed for ${ref}"
    return 1
  fi
}

# sync_image REF IDENTITY → _desired_id = image ID of REPO:verified.
# Returns 1 only when no verified image exists locally at all. If this cycle's
# verification failed, the previously verified image stays the desired state.
sync_image() {
  local ref="$1" identity="$2"
  _desired_id=""
  if ! split_ref "${ref}"; then
    set_unhealthy "Unsupported image reference (digest refs not allowed): ${ref}"
    return 1
  fi
  if verify_remote "${_repo}:${_tag}" "${identity}"; then
    ensure_verified_local "${_repo}" "${_tag}" "${_digest}" || true
  fi
  _desired_id=$(docker image inspect "${_repo}:${VERIFIED_TAG}" --format '{{.Id}}' 2>/dev/null) || _desired_id=""
  [[ -n "${_desired_id}" ]]
}

# compose_container_image PROJECT SERVICE → _actual_id ("" if no running container exists)
compose_container_image() {
  local ids
  _actual_id=""
  ids=$(docker ps \
          --filter status=running \
          --filter "label=com.docker.compose.project=$1" \
          --filter "label=com.docker.compose.service=$2" \
          --format '{{.ID}}') || return 1
  [[ -n "${ids}" ]] || return 0
  _actual_id=$(docker inspect "${ids%%$'\n'*}" --format '{{.Image}}') || return 1
}

_last_prune=0
maybe_prune() {
  local now; now=$(date +%s)
  (( now - _last_prune >= PRUNE_INTERVAL )) || return 0
  _last_prune=${now}
  # Dangling only (old images left behind by re-tagging), and only once they are a day old.
  if docker image prune -f --filter "until=24h" > /dev/null 2>&1; then
    log info "Pruned dangling images"
  else
    log warn "Image prune failed"
  fi
}

# sleep in the foreground would defer the SIGTERM trap until it returns.
interruptible_sleep() {
  sleep "$1" &
  wait "$!" || true
}

# ---------------------------------------------------------------------------
# 1. Deployer self-update — delegated to an external sibling helper container
# ---------------------------------------------------------------------------
# The helper runs `docker compose up -d --no-deps deployer` from OUTSIDE our lifecycle.
# It runs with -w <project dir> and mounts, read-only at their real host paths, the
# project dir plus the directory of every COMPOSE_FILE entry. Compose then reads
# COMPOSE_FILE from the project .env and resolves its relative entries (relative to the
# working directory, not --project-directory), including sibling plugin overlays like
# ../infra-vault/docker-compose.infra-runner.yml — without exposing the rest of the
# home directory (e.g. ~/.ssh). Arguments are passed as argv, never as a shell string.

# helper_mounts → _mounts (-v args)
helper_mounts() {
  local -A seen=()
  local entry dir
  _mounts=()
  local IFS="${COMPOSE_PATH_SEPARATOR:-:}"
  for entry in ${COMPOSE_FILE:-} .; do
    [[ -n "${entry}" ]] || continue
    [[ "${entry}" == /* ]] || entry="${COMPOSE_PROJECT_DIR}/${entry}"
    if [[ "${entry}" == . || "${entry}" == "${COMPOSE_PROJECT_DIR}/." ]]; then
      dir="${COMPOSE_PROJECT_DIR}"
    else
      dir="$(dirname "${entry}")"
    fi
    dir="$(realpath -m "${dir}")"
    [[ -z "${seen[${dir}]:-}" ]] || continue
    seen[${dir}]=1
    _mounts+=(-v "${dir}:${dir}:ro")
  done
}

self_update() {
  local proxy_net="${COMPOSE_PROJECT_NAME}_deployer-proxy-net"
  helper_mounts

  docker rm -f "${HELPER_NAME}" > /dev/null 2>&1 || true
  log info "Launching self-update helper" name "${HELPER_NAME}"
  if ! docker run -d \
       --name "${HELPER_NAME}" \
       --network "${proxy_net}" \
       -e DOCKER_HOST=tcp://deployer-proxy:2375 \
       -e COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME}" \
       "${_mounts[@]}" \
       -w "${COMPOSE_PROJECT_DIR}" \
       --label infra-runner.role=deployer-selfupdate \
       --entrypoint docker \
       "${DEPLOYER_REPO}:${VERIFIED_TAG}" \
       compose --project-name "${COMPOSE_PROJECT_NAME}" \
               --project-directory "${COMPOSE_PROJECT_DIR}" \
               up -d --no-deps deployer \
       > /dev/null 2> "${_ERR_FILE}"; then
    log error "Failed to launch self-update helper" detail "$(err_tail)"
    set_unhealthy "Failed to launch self-update helper"
    return 1
  fi

  # When compose stops us, the SIGTERM trap exits. Still running here means the helper
  # failed or did not replace us: report it and carry on with the rest of the cycle —
  # the next cycle retries, because the running image still differs from :verified.
  local waited=0 succeeded_at=-1 state
  while (( waited < SELF_UPDATE_TIMEOUT )); do
    interruptible_sleep 3
    waited=$(( waited + 3 ))
    state=$(docker inspect "${HELPER_NAME}" --format '{{.State.Status}} {{.State.ExitCode}}' 2>/dev/null) || continue
    case "${state}" in
      "exited 0")
        (( succeeded_at >= 0 )) || succeeded_at=${waited}
        if (( waited - succeeded_at >= 30 )); then
          log error "Self-update helper succeeded but this deployer was not replaced" \
            logs "$(docker logs --tail 20 "${HELPER_NAME}" 2>&1 | tr '\n' ' ' | cut -c1-1000)"
          set_unhealthy "Self-update helper finished but the deployer was not replaced"
          return 1
        fi
        ;;
      exited*)
        log error "Self-update helper failed" exit_code "${state#exited }" \
          logs "$(docker logs --tail 20 "${HELPER_NAME}" 2>&1 | tr '\n' ' ' | cut -c1-1000)"
        set_unhealthy "Self-update helper failed (exit ${state#exited })"
        return 1
        ;;
    esac
  done
  set_unhealthy "Self-update helper did not replace deployer within ${SELF_UPDATE_TIMEOUT}s"
  return 1
}

reconcile_deployer() {
  sync_image "${DEPLOYER_REPO}:latest" "${CERT_IDENTITY}" || return 0
  if ! compose_container_image "${COMPOSE_PROJECT_NAME}" deployer; then
    set_unhealthy "Cannot inspect the deployer container"
    return 0
  fi
  if [[ -z "${_actual_id}" ]]; then
    set_unhealthy "Running deployer container not found via compose labels — self-update skipped"
    return 0
  fi
  [[ "${_actual_id}" != "${_desired_id}" ]] || return 0
  log info "Deployer image changed — self-updating" running "${_actual_id}" verified "${_desired_id}"
  self_update || true
}

# ---------------------------------------------------------------------------
# 2. Controller
# ---------------------------------------------------------------------------
reconcile_controller() {
  sync_image "${CONTROLLER_REPO}:latest" "${CERT_IDENTITY}" || return 0
  if ! compose_container_image "${COMPOSE_PROJECT_NAME}" controller; then
    set_unhealthy "Cannot inspect the controller container"
    return 0
  fi
  [[ "${_actual_id}" != "${_desired_id}" ]] || return 0
  log info "Controller image changed — updating" running "${_actual_id:-none}" verified "${_desired_id}"
  if ! "${COMPOSE[@]}" up -d --no-deps controller; then
    set_unhealthy "docker compose up -d controller failed"
    return 0
  fi
  if ! compose_container_image "${COMPOSE_PROJECT_NAME}" controller; then
    set_unhealthy "Cannot inspect the controller container after compose up"
    return 0
  fi
  if [[ "${_actual_id}" != "${_desired_id}" ]]; then
    set_unhealthy "Controller still not running on the verified image after compose up — check its image ref in docker-compose.yml"
    return 0
  fi
  log info "Controller updated successfully"
}

# ---------------------------------------------------------------------------
# 3. Plugins — generic drop-in deployer
# ---------------------------------------------------------------------------
# Descriptors are parsed as DATA — they are never `source`d, so a descriptor cannot run
# commands in the deployer. Hook scripts DO run code: they get a minimal environment and
# a timeout (see run_plugin_hooks). See deployer/PLUGINS.md.

declare -gA P=()                 # the descriptor being processed
declare -gA _hooks_pending=()    # plugin name → 1 while a blocking on_update hook keeps failing
declare -gA _legacy_env_warned=()
declare -gA _seen_plugins=()      # plugin name → descriptor path within this cycle

_KEY_RE='^(export[[:space:]]+)?([A-Z][A-Z0-9_]*)=(.*)$'
_HOOK_KEY_RE='^PLUGIN_POST_DEPLOY_[0-9]+_(SCRIPT|RUN|BLOCKING|TIMEOUT)$'
# shellcheck disable=SC2016  # literal regex: '$' must not expand
_VAR_RE='^([^$]*)\$(\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))(.*)$'

# expand_vars STRING → _expanded. Substitutes ${NAME} / $NAME from the EXPORTED
# environment only. No command substitution, arithmetic or other shell expansion.
expand_vars() {
  local s="$1" out="" name
  while [[ "${s}" =~ ${_VAR_RE} ]]; do
    out+="${BASH_REMATCH[1]}"
    name="${BASH_REMATCH[3]:-${BASH_REMATCH[4]}}"
    s="${BASH_REMATCH[5]}"
    if [[ "$(declare -p "${name}" 2>/dev/null)" == "declare -x"* ]]; then
      out+="${!name}"
    else
      log warn "Undefined variable in plugin descriptor" var "${name}"
    fi
  done
  _expanded="${out}${s}"
}

# parse_descriptor FILE → P[KEY]=VALUE
# shellcheck disable=SC2094  # `log` writes to stdout, not to the descriptor file
parse_descriptor() {
  local file="$1" line key val lineno=0
  P=()
  while IFS= read -r line || [[ -n "${line}" ]]; do
    lineno=$(( lineno + 1 ))
    line="${line#"${line%%[![:space:]]*}"}"     # trim leading whitespace
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    if [[ ! "${line}" =~ ${_KEY_RE} ]]; then
      log warn "Ignoring unparseable plugin descriptor line" file "${file}" line "${lineno}"
      continue
    fi
    key="${BASH_REMATCH[2]}"
    val="${BASH_REMATCH[3]}"
    case "${key}" in
      PLUGIN_NAME|PLUGIN_IMAGE|PLUGIN_CERT_IDENTITY|PLUGIN_COMPOSE_PROJECT|PLUGIN_COMPOSE_DIR|PLUGIN_COMPOSE_SERVICE|PLUGIN_HOOK_ENV) ;;
      *)
        if [[ ! "${key}" =~ ${_HOOK_KEY_RE} ]]; then
          log warn "Ignoring unknown plugin descriptor key" file "${file}" key "${key}"
          continue
        fi
        ;;
    esac
    if [[ "${val}" =~ ^\'([^\']*)\'[[:space:]]*(#.*)?$ ]]; then
      P["${key}"]="${BASH_REMATCH[1]}"                 # single quotes: literal
      continue
    elif [[ "${val}" =~ ^\"([^\"]*)\"[[:space:]]*(#.*)?$ ]]; then
      val="${BASH_REMATCH[1]}"
    else
      val="${val%%[[:space:]]#*}"                       # strip trailing comment
      val="${val%"${val##*[![:space:]]}"}"             # trim trailing whitespace
    fi
    expand_vars "${val}"
    P["${key}"]="${_expanded}"
  done < "${file}"
}

# Builds _hook_env (NAME=VALUE list for `env -i`).
build_hook_env() {
  local name
  _hook_env=("PATH=${PATH}" "HOME=${HOME:-/root}" "DOCKER_HOST=${DOCKER_HOST:-}"
             "PLUGIN_NAME=${P[PLUGIN_NAME]}" "PLUGIN_COMPOSE_DIR=${P[PLUGIN_COMPOSE_DIR]}")
  local allow="${P[PLUGIN_HOOK_ENV]:-} ${PLUGIN_HOOK_ENV:-}"
  if [[ -n "${allow// /}" ]]; then
    for name in ${allow//,/ }; do
      [[ "${name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
      case "${name}" in
        GITHUB_TOKEN|GITHUB_APP_*)
          log warn "GitHub credential cannot be passed to a plugin hook" plugin "${P[PLUGIN_NAME]}" var "${name}"
          continue
          ;;
      esac
      [[ "$(declare -p "${name}" 2>/dev/null)" == "declare -x"* ]] && _hook_env+=("${name}=${!name}")
    done
    return 0
  fi
  # Legacy: no allowlist declared → full environment minus GitHub credentials.
  if [[ -z "${_legacy_env_warned[${P[PLUGIN_NAME]}]:-}" ]]; then
    log warn "Plugin hooks inherit the full deployer environment (minus GitHub credentials); declare PLUGIN_HOOK_ENV to restrict it" \
      plugin "${P[PLUGIN_NAME]}"
    _legacy_env_warned[${P[PLUGIN_NAME]}]=1
  fi
  while read -r name; do
    case "${name}" in
      GITHUB_TOKEN|GITHUB_APP_*|PATH|HOME|DOCKER_HOST|PLUGIN_NAME|PLUGIN_COMPOSE_DIR) continue ;;
    esac
    _hook_env+=("${name}=${!name}")
  done < <(compgen -e)
}

# run_plugin_hooks UPDATED → 1 if a blocking hook failed or a hook timeout is invalid
run_plugin_hooks() {
  local updated="$1" i rc=0 script run blocking tmo abs status
  for (( i = 0; ; i++ )); do
    script="${P[PLUGIN_POST_DEPLOY_${i}_SCRIPT]:-}"
    [[ -n "${script}" ]] || break
    run="${P[PLUGIN_POST_DEPLOY_${i}_RUN]:-on_update}"
    blocking="${P[PLUGIN_POST_DEPLOY_${i}_BLOCKING]:-true}"
    tmo="${P[PLUGIN_POST_DEPLOY_${i}_TIMEOUT]:-${PLUGIN_HOOK_TIMEOUT}}"
    if [[ "${run}" != always && ! ( "${run}" == on_update && "${updated}" == true ) ]]; then
      continue
    fi
    if [[ ! "${tmo}" =~ ^[1-9][0-9]{0,3}$ ]] || (( tmo > 3600 )); then
      set_unhealthy "Invalid timeout for plugin ${P[PLUGIN_NAME]} hook ${i}: ${tmo}"
      rc=1
      continue
    fi
    abs="${P[PLUGIN_COMPOSE_DIR]}/${script}"
    build_hook_env
    log info "Running post-deploy hook" plugin "${P[PLUGIN_NAME]}" script "${abs}" run "${run}"
    status=0
    timeout --kill-after=5s "${tmo}" env -i "${_hook_env[@]}" bash "${abs}" || status=$?
    if (( status == 0 )); then
      log info "Post-deploy hook succeeded" script "${abs}"
      continue
    fi
    local why="exit ${status}"
    (( status == 124 )) && why="timed out after ${tmo}s"
    if [[ "${blocking}" == true ]]; then
      set_unhealthy "Post-deploy hook failed (${why}): ${abs}"
      rc=1
    else
      log warn "Post-deploy hook failed (non-blocking)" script "${abs}" reason "${why}"
    fi
  done
  return "${rc}"
}

process_plugin() {
  local descriptor="$1"
  parse_descriptor "${descriptor}"
  local k
  for k in PLUGIN_NAME PLUGIN_IMAGE PLUGIN_CERT_IDENTITY PLUGIN_COMPOSE_PROJECT PLUGIN_COMPOSE_DIR PLUGIN_COMPOSE_SERVICE; do
    if [[ -z "${P[${k}]:-}" ]]; then
      set_unhealthy "Plugin descriptor ${descriptor} missing required field ${k}"
      return 0
    fi
  done
  if [[ ! "${P[PLUGIN_NAME]}" =~ ^[A-Za-z0-9-]+$ ]]; then
    set_unhealthy "Invalid PLUGIN_NAME in ${descriptor} (alphanumerics and hyphens only)"
    return 0
  fi
  if [[ -n "${_seen_plugins[${P[PLUGIN_NAME]}]:-}" ]]; then
    set_unhealthy "Duplicate PLUGIN_NAME ${P[PLUGIN_NAME]} in ${descriptor} and ${_seen_plugins[${P[PLUGIN_NAME]}]}"
    return 0
  fi
  _seen_plugins[${P[PLUGIN_NAME]}]="${descriptor}"

  local name="${P[PLUGIN_NAME]}" service_verified=false
  log info "Checking plugin" plugin "${name}" image "${P[PLUGIN_IMAGE]}"

  if sync_image "${P[PLUGIN_IMAGE]}" "${P[PLUGIN_CERT_IDENTITY]}"; then
    if ! compose_container_image "${P[PLUGIN_COMPOSE_PROJECT]}" "${P[PLUGIN_COMPOSE_SERVICE]}"; then
      set_unhealthy "Cannot inspect plugin container for ${name}"
    elif [[ "${_actual_id}" != "${_desired_id}" ]]; then
      log info "Plugin image changed — updating service" plugin "${name}" service "${P[PLUGIN_COMPOSE_SERVICE]}"
      # env -u: the deployer's own COMPOSE_FILE/COMPOSE_PROJECT_NAME must not leak into the
      # plugin's compose invocation; the plugin's compose file is discovered via --project-directory.
      if env -u COMPOSE_FILE -u COMPOSE_PROJECT_NAME docker compose \
           --project-name "${P[PLUGIN_COMPOSE_PROJECT]}" \
           --project-directory "${P[PLUGIN_COMPOSE_DIR]}" \
           up -d --no-deps "${P[PLUGIN_COMPOSE_SERVICE]}"; then
        _hooks_pending[${name}]=1
        if ! compose_container_image "${P[PLUGIN_COMPOSE_PROJECT]}" "${P[PLUGIN_COMPOSE_SERVICE]}"; then
          set_unhealthy "Plugin ${name}: cannot inspect service after compose up"
        elif [[ "${_actual_id}" != "${_desired_id}" ]]; then
          set_unhealthy "Plugin ${name}: service still not running on the verified image — its compose image ref must be ${P[PLUGIN_IMAGE]} without pull_policy: always"
        else
          service_verified=true
          log info "Plugin service updated" plugin "${name}"
        fi
      else
        set_unhealthy "docker compose up failed for plugin ${name}"
      fi
    else
      service_verified=true
    fi
  fi

  # Keep a pending hook across inspection failures, but run it only after the
  # updated service is observed running on the verified image.
  local run_on_update=false
  if [[ -n "${_hooks_pending[${name}]:-}" && "${service_verified}" == true ]]; then
    run_on_update=true
  fi
  if run_plugin_hooks "${run_on_update}"; then
    if [[ "${run_on_update}" == true ]]; then
      unset "_hooks_pending[${name}]"
    fi
  fi
}

run_plugins() {
  [[ -d "${PLUGINS_DIR}" ]] || return 0
  local descriptor files=()
  _seen_plugins=()
  shopt -s nullglob
  files=("${PLUGINS_DIR%/}"/*.plugin)
  shopt -u nullglob
  for descriptor in "${files[@]}"; do
    [[ -f "${descriptor}" ]] || continue
    process_plugin "${descriptor}" || true
  done
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

# Runs in an errexit-ignored context (`if run_cycle`): every step checks its own errors.
run_cycle() {
  _cycle_reasons=()
  ensure_health_server
  reconcile_deployer
  reconcile_controller
  sync_image "${RUNNER_REPO}:latest" "${CERT_IDENTITY}" || true
  run_plugins

  if (( ${#_cycle_reasons[@]} == 0 )); then
    write_health ok
    maybe_prune
  else
    local joined
    printf -v joined '%s; ' "${_cycle_reasons[@]}"
    write_health unhealthy "${joined%; }"
  fi
}

shutdown() {
  trap - SIGTERM SIGINT
  log info "Shutting down"
  [[ -n "${HEALTH_SERVER_PID}" ]] && kill "${HEALTH_SERVER_PID}" 2>/dev/null
  rm -f "${_ERR_FILE}"
  exit 0
}

main() {
  trap shutdown SIGTERM SIGINT
  write_health starting
  ensure_health_server

  log info "Deployer starting" project "${COMPOSE_PROJECT_NAME}" poll_interval "${POLL_INTERVAL}s"
  log info "Signature policy" identity "${CERT_IDENTITY}"

  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    log info "Authenticating with GHCR (PAT)"
    ghcr_login
  else
    log info "No GITHUB_TOKEN — pulling public images anonymously"
  fi

  # A helper left over from a previous self-update has done its job if we are running.
  docker rm -f "${HELPER_NAME}" > /dev/null 2>&1 || true

  while true; do
    if ! run_cycle; then
      set_unhealthy "Deploy cycle aborted unexpectedly"
    fi
    interruptible_sleep "${POLL_INTERVAL}"
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
