#!/bin/bash
# bootstrap-images.sh — verify, pull and tag the stack's images before the first start.
#
# docker-compose.yml runs controller, deployer and runners from the LOCAL tag :verified,
# which only the deployer sets after cosign verification. On a fresh host (or after
# `docker image prune -a`) nothing carries that tag yet, so run this once before
# `docker compose up -d`. It does what the deployer does each cycle:
#
#   cosign verify <image>:latest  → digest cosign actually verified
#   docker pull <image>@<digest>  → never an unverified tag
#   docker tag  … :verified and :latest
#
# cosign runs from a digest-pinned container image (same pin as deployer/Dockerfile),
# so the host needs only docker and jq. Run as the user that owns the stack (ghrunner).
set -euo pipefail

COSIGN_IMAGE="gcr.io/projectsigstore/cosign:v2.4.1@sha256:b03690aa52bfe94054187142fba24dc54137650682810633901767d8a3e15b31"
OIDC_ISSUER="https://token.actions.githubusercontent.com"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/.env"
  set +a
fi
GITHUB_ORG="${GITHUB_ORG:?GITHUB_ORG is required (set it in .env)}"
GITHUB_REPO="${GITHUB_REPO:-infra-runner}"
IDENTITY="https://github.com/${GITHUB_ORG}/${GITHUB_REPO}/.github/workflows/deploy.yml@refs/heads/main"

command -v jq > /dev/null || { echo "ERROR: jq is required" >&2; exit 1; }

# Registry credentials for private images (PAT path, after scripts/ghcr-login.sh).
cosign_auth=()
if [[ -f "${HOME}/.docker/config.json" ]]; then
  cosign_auth=(-e DOCKER_CONFIG=/docker-config -v "${HOME}/.docker/config.json:/docker-config/config.json:ro")
fi

for name in uye-deployer infra-runner-controller infra-runner; do
  repo="ghcr.io/${GITHUB_ORG}/${name}"
  echo "==> ${repo}:latest"
  out=$(docker run --rm "${cosign_auth[@]}" "${COSIGN_IMAGE}" verify \
          --certificate-identity "${IDENTITY}" \
          --certificate-oidc-issuer "${OIDC_ISSUER}" \
          "${repo}:latest")
  digest=$(jq -r '[.[].critical.image."docker-manifest-digest"] | unique
                  | if length == 1 then .[0] else empty end' <<< "${out}")
  [[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "ERROR: could not determine verified digest for ${repo}" >&2; exit 1; }
  echo "    verified ${digest}"
  docker pull --quiet "${repo}@${digest}" > /dev/null
  docker tag "${repo}@${digest}" "${repo}:verified"
  docker tag "${repo}@${digest}" "${repo}:latest"
done

echo
echo "All images verified and tagged. Start the stack with: docker compose up -d"
