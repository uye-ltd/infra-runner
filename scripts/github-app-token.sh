#!/bin/bash
# GitHub App authentication helper — source this file, do not execute it.
# After sourcing, call generate_installation_token() to print a fresh
# installation access token to stdout.
#
# Required env vars (validated by the caller before sourcing):
#   GITHUB_APP_ID                — numeric GitHub App ID
#   GITHUB_APP_INSTALLATION_ID   — numeric installation ID
#   GITHUB_APP_PRIVATE_KEY_PATH  — path to the PEM private key (read-only mount)

_b64url() {
  openssl base64 -e -A | tr '+/' '-_' | tr -d '='
}

_make_jwt() {
  local app_id="$1" key_path="$2"
  local now iat exp
  now=$(date +%s)
  iat=$(( now - 60 ))   # backdate 60 s to absorb clock skew vs GitHub servers
  exp=$(( now + 540 ))  # 9 min; GitHub's hard max for App JWTs is 10 min

  local header payload unsigned sig
  header=$(printf '{"alg":"RS256","typ":"JWT"}' | _b64url)
  payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "${iat}" "${exp}" "${app_id}" | _b64url)
  unsigned="${header}.${payload}"
  sig=$(printf '%s' "${unsigned}" | openssl dgst -sha256 -sign "${key_path}" | _b64url)
  printf '%s.%s' "${unsigned}" "${sig}"
}

generate_installation_token() {
  local jwt
  jwt=$(_make_jwt "${GITHUB_APP_ID}" "${GITHUB_APP_PRIVATE_KEY_PATH}")

  local token
  token=$(curl -fsSL \
    -X POST \
    -H "Authorization: Bearer ${jwt}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/app/installations/${GITHUB_APP_INSTALLATION_ID}/access_tokens" \
    | jq -r '.token // empty')

  [[ -n "${token}" ]] || return 1
  printf '%s' "${token}"
}
