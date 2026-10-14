#!/bin/bash
# Source after scripts/logging.sh. Write deployer Docker registry auth for a classic PAT.
write_ghcr_auth() {
  local config_dir="${DOCKER_CONFIG:-/root/.docker}" auth_b64 temp
  if [[ ! "${GHCR_USERNAME:-}" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]]; then
    log error "GHCR_USERNAME must be the GitHub username that owns GITHUB_TOKEN"
    return 1
  fi
  if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    log error "GITHUB_TOKEN is required for GHCR authentication"
    return 1
  fi
  auth_b64=$(printf '%s:%s' "${GHCR_USERNAME}" "${GITHUB_TOKEN}" | base64 | tr -d '\n') || return 1
  if ! mkdir -p "${config_dir}" || ! temp=$(mktemp "${config_dir}/config.XXXXXX"); then
    log error "Could not write GHCR Docker auth config" path "${config_dir}"
    return 1
  fi
  if ! printf '{"auths":{"ghcr.io":{"auth":"%s"}}}\n' "${auth_b64}" > "${temp}" \
     || ! mv -f "${temp}" "${config_dir}/config.json"; then
    rm -f "${temp}"
    log error "Could not write GHCR Docker auth config" path "${config_dir}"
    return 1
  fi
}
