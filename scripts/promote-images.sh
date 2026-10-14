#!/bin/bash
# Promote a release only after all three :sha images have valid signatures.
# GitHub Actions runs this after the publish matrix succeeds; the same script can
# be exercised locally with stubbed cosign/docker (tests/promote-images.bats).
set -euo pipefail

GITHUB_REPOSITORY="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
GITHUB_REPOSITORY_OWNER="${GITHUB_REPOSITORY_OWNER:?GITHUB_REPOSITORY_OWNER is required}"
GITHUB_SHA="${GITHUB_SHA:?GITHUB_SHA is required}"

identity="https://github.com/${GITHUB_REPOSITORY}/.github/workflows/deploy.yml@refs/heads/main"
names=(infra-runner infra-runner-controller uye-deployer)
images=() digests=()

for name in "${names[@]}"; do
  image="ghcr.io/${GITHUB_REPOSITORY_OWNER}/${name}"
  verified=$(cosign verify \
    --certificate-identity "${identity}" \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    "${image}:${GITHUB_SHA}")
  digest=$(jq -er '[.[].critical.image."docker-manifest-digest"] | unique
    | if length == 1 then .[0] else empty end' <<< "${verified}")
  [[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || {
    echo "Invalid verified digest for ${image}: ${digest}" >&2
    exit 1
  }
  images+=("${image}")
  digests+=("${digest}")
done

metadata=$(mktemp "${TMPDIR:-/tmp}/infra-runner-promote.XXXXXX")
trap 'rm -f "${metadata}"' EXIT
for i in "${!images[@]}"; do
  docker buildx imagetools create --prefer-index=false \
    --metadata-file "${metadata}" \
    --tag "${images[i]}:latest" "${images[i]}@${digests[i]}"
  promoted=$(jq -r '."containerimage.descriptor".digest' "${metadata}")
  [[ "${promoted}" == "${digests[i]}" ]] || {
    echo "Promoted digest ${promoted} differs from signed digest ${digests[i]}" >&2
    exit 1
  }
done
