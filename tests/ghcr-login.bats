#!/usr/bin/env bats
# Host GHCR login must use a classic PAT and never mint an unusable App token.

setup() {
  export ST="${BATS_TEST_TMPDIR}/state" CALLS="${BATS_TEST_TMPDIR}/calls"
  mkdir -p "${ST}" "${BATS_TEST_TMPDIR}/repo/scripts"
  : > "${CALLS}"
  cp "${BATS_TEST_DIRNAME}/../scripts/ghcr-login.sh" \
     "${BATS_TEST_DIRNAME}/../scripts/logging.sh" \
     "${BATS_TEST_TMPDIR}/repo/scripts/"
  export PATH="${BATS_TEST_DIRNAME}/stubs/ghcr:${PATH}"
}

login() { bash "${BATS_TEST_TMPDIR}/repo/scripts/ghcr-login.sh"; }

@test "classic PAT is passed to docker login over stdin" {
  printf 'GITHUB_TOKEN=ghp_testtoken\nGHCR_USERNAME=octocat\n' > "${BATS_TEST_TMPDIR}/repo/.env"
  run login
  [ "${status}" -eq 0 ]
  [ "$(cat "${ST}/password")" = ghp_testtoken ]
  grep -Fxq 'login ghcr.io -u octocat --password-stdin' "${CALLS}"
  [[ "${output}" != *ghp_testtoken* ]]
}

@test "PAT without its GitHub username fails before docker login" {
  printf 'GITHUB_TOKEN=ghp_testtoken\n' > "${BATS_TEST_TMPDIR}/repo/.env"
  run env -u GHCR_USERNAME bash "${BATS_TEST_TMPDIR}/repo/scripts/ghcr-login.sh"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *'GHCR_USERNAME must be the GitHub username'* ]]
  [ ! -s "${CALLS}" ]
}

@test "GitHub App configuration fails before docker login" {
  printf 'GITHUB_APP_ID=123\nGITHUB_APP_INSTALLATION_ID=456\n' > "${BATS_TEST_TMPDIR}/repo/.env"
  run env -u GITHUB_TOKEN bash "${BATS_TEST_TMPDIR}/repo/scripts/ghcr-login.sh"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *'GHCR login requires GITHUB_TOKEN (classic PAT)'* ]]
  [ ! -s "${CALLS}" ]
}
