#!/usr/bin/env bats
# The watched tags must remain untouched until every candidate is verified.

setup() {
  export ST="${BATS_TEST_TMPDIR}/state" CALLS="${BATS_TEST_TMPDIR}/calls"
  mkdir -p "${ST}"; : > "${CALLS}"
  export PATH="${BATS_TEST_DIRNAME}/stubs/promotion:${PATH}"
  export GITHUB_REPOSITORY=acme/infra-runner GITHUB_REPOSITORY_OWNER=acme
  export GITHUB_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
}

promote() { bash "${BATS_TEST_DIRNAME}/../scripts/promote-images.sh"; }

@test "all three candidates are verified before any latest tag moves" {
  run promote
  [ "${status}" -eq 0 ]
  [ "$(grep -c '^cosign ' "${CALLS}")" -eq 3 ]
  [ "$(grep -c '^docker ' "${CALLS}")" -eq 3 ]
  [ "$(head -n 3 "${CALLS}" | grep -c '^cosign ')" -eq 3 ]
  grep -q -- '--prefer-index=false' "${CALLS}"
}

@test "a failed candidate signature prevents every promotion" {
  touch "${ST}/fail_uye-deployer"
  run promote
  [ "${status}" -ne 0 ]
  [ "$(grep -c '^cosign ' "${CALLS}")" -eq 3 ]
  ! grep -q '^docker ' "${CALLS}"
}

@test "a malformed signed digest prevents every promotion" {
  touch "${ST}/invalid_infra-runner-controller"
  run promote
  [ "${status}" -ne 0 ]
  ! grep -q '^docker ' "${CALLS}"
}

@test "promotion stops if the registry changes a signed digest" {
  touch "${ST}/metadata_mismatch"
  run promote
  [ "${status}" -ne 0 ]
  [[ "${output}" == *'differs from signed digest'* ]]
  [ "$(grep -c '^docker ' "${CALLS}")" -eq 1 ]
}
