#!/bin/bash
# Refresh a GitHub App installation token and log in to ghcr.io.
# Run before `docker compose pull` if more than 1 hour has elapsed since the
# last login — GitHub App installation tokens expire after 1 hour.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load .env from the repo root so this script works when run standalone
# (outside of a docker-compose environment that would inject the vars).
if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -a
  # shellcheck source=../.env
  source "${REPO_ROOT}/.env"
  set +a
fi

LOG_SVC=ghcr-login
# shellcheck source=logging.sh
source "${SCRIPT_DIR}/logging.sh"

# ---------------------------------------------------------------------------
# Authentication — mirrors the same two paths used by controller / deployer
# ---------------------------------------------------------------------------
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  log info "Using static GITHUB_TOKEN"
  token="${GITHUB_TOKEN}"
else
  GITHUB_APP_ID="${GITHUB_APP_ID:?GITHUB_APP_ID is required (or set GITHUB_TOKEN directly)}"
  GITHUB_APP_INSTALLATION_ID="${GITHUB_APP_INSTALLATION_ID:?GITHUB_APP_INSTALLATION_ID is required}"
  # Prefer the host path when running outside a container (e.g. manual ghcr-login.sh).
  # GITHUB_APP_PRIVATE_KEY_PATH points to the in-container mount (/run/secrets/...),
  # which does not exist on the host.
  GITHUB_APP_PRIVATE_KEY_PATH="${GITHUB_APP_PRIVATE_KEY_HOST_PATH:-${GITHUB_APP_PRIVATE_KEY_PATH:?GITHUB_APP_PRIVATE_KEY_PATH is required}}"
  [[ -r "${GITHUB_APP_PRIVATE_KEY_PATH}" ]] \
    || { log error "Private key not readable" path="${GITHUB_APP_PRIVATE_KEY_PATH}"; exit 1; }

  # shellcheck source=github-app-token.sh
  source "${SCRIPT_DIR}/github-app-token.sh"

  log info "Generating GitHub App installation token"
  token=$(generate_installation_token) \
    || { log error "Failed to generate installation token"; exit 1; }
fi

log info "Logging in to ghcr.io"
printf '%s' "${token}" | docker login ghcr.io -u x-access-token --password-stdin \
  || { log error "docker login failed"; exit 1; }

log info "GHCR login succeeded"
