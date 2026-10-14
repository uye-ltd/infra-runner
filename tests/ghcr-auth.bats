#!/usr/bin/env bats
# Deployer Docker auth config writer.

setup() {
  export DOCKER_CONFIG="${BATS_TEST_TMPDIR}/docker-config"
  export GITHUB_TOKEN=ghp_testtoken GHCR_USERNAME=octocat
  LOG_SVC=test
  source "${BATS_TEST_DIRNAME}/../scripts/logging.sh"
  source "${BATS_TEST_DIRNAME}/../scripts/ghcr-auth.sh"
}

@test "Docker auth config contains PAT owner and token with private permissions" {
  write_ghcr_auth
  local encoded decoded
  encoded=$(jq -r '.auths["ghcr.io"].auth' "${DOCKER_CONFIG}/config.json")
  decoded=$(python3 -c 'import base64,sys; print(base64.b64decode(sys.argv[1]).decode())' "${encoded}")
  [ "${decoded}" = octocat:ghp_testtoken ]
  [ "$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "${DOCKER_CONFIG}/config.json")" = 0o600 ]
}

@test "missing or malformed PAT username is rejected without writing credentials" {
  local value
  for value in '' 'bad:name' 'bad name'; do
    GHCR_USERNAME="${value}"
    if write_ghcr_auth > /dev/null 2>&1; then
      echo "Unexpectedly accepted GHCR_USERNAME=${value}" >&2
      return 1
    fi
    [ ! -e "${DOCKER_CONFIG}/config.json" ]
  done
}
