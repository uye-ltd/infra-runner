#!/usr/bin/env bats
# Exercise first-start image verification without a Docker daemon.

refute() { if "$@"; then echo "refute: unexpectedly succeeded: $*" >&2; return 1; fi; }

setup() {
  export ST="${BATS_TEST_TMPDIR}/state" CALLS="${BATS_TEST_TMPDIR}/calls"
  export HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "${ST}" "${HOME}" "${BATS_TEST_TMPDIR}/repo/scripts"
  : > "${CALLS}"
  printf 'GITHUB_ORG=acme\nGITHUB_REPO=infra-runner\n' > "${BATS_TEST_TMPDIR}/repo/.env"
  cp "${BATS_TEST_DIRNAME}/../scripts/bootstrap-images.sh" \
     "${BATS_TEST_TMPDIR}/repo/scripts/bootstrap-images.sh"
  export PATH="${BATS_TEST_DIRNAME}/stubs/bootstrap:${PATH}"
}

bootstrap() { bash "${BATS_TEST_TMPDIR}/repo/scripts/bootstrap-images.sh"; }

@test "bootstrap verifies and pulls each signed digest" {
  run bootstrap
  [ "${status}" -eq 0 ]
  [ "$(grep -c '^docker run' "${CALLS}")" -eq 3 ]
  [ "$(grep -c '^docker pull' "${CALLS}")" -eq 3 ]
  [ "$(grep -c '^docker tag' "${CALLS}")" -eq 6 ]
  refute grep -qE '^docker pull .*:latest$' "${CALLS}"
}

@test "bootstrap rejects malformed cosign digest before pulling that image" {
  touch "${ST}/malformed_digest"
  run bootstrap
  [ "${status}" -ne 0 ]
  [[ "${output}" == *'could not determine verified digest for ghcr.io/acme/infra-runner-controller'* ]]
  [ "$(grep -c '^docker pull' "${CALLS}")" -eq 1 ]
  refute grep -q 'docker pull .*infra-runner-controller' "${CALLS}"
  refute grep -q 'docker tag .*infra-runner-controller' "${CALLS}"
}

@test "bootstrap stops on signature failure without pulling an image" {
  touch "${ST}/bad_signature"
  run bootstrap
  [ "${status}" -ne 0 ]
  refute grep -q '^docker pull' "${CALLS}"
  refute grep -q '^docker tag' "${CALLS}"
}
