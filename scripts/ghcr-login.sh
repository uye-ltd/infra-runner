#!/bin/bash
# Log in to GHCR on the host with a classic PAT for private packages.
# GitHub App installation tokens cannot authenticate to GHCR. Public packages
# can be pulled anonymously without running this script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load .env from the repo root so this script works when run standalone
# (outside of a docker-compose environment that would inject the vars).
if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -a
  # shellcheck source=/dev/null  # operator-provided, not in the repo
  source "${REPO_ROOT}/.env"
  set +a
fi

LOG_SVC=ghcr-login
# shellcheck source=logging.sh
source "${SCRIPT_DIR}/logging.sh"

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  log error "GHCR login requires GITHUB_TOKEN (classic PAT); GitHub App tokens cannot access GHCR"
  exit 1
fi
if [[ ! "${GHCR_USERNAME:-}" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]]; then
  log error "GHCR_USERNAME must be the GitHub username that owns GITHUB_TOKEN"
  exit 1
fi

log info "Logging in to ghcr.io"
printf '%s' "${GITHUB_TOKEN}" | docker login ghcr.io -u "${GHCR_USERNAME}" --password-stdin \
  || { log error "docker login failed"; exit 1; }

log info "GHCR login succeeded"
