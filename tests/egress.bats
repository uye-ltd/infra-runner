#!/usr/bin/env bats
# Firewall setup against a stateful iptables stub; no host firewall access needed.

setup() {
  export ST="${BATS_TEST_TMPDIR}/state" CALLS="${BATS_TEST_TMPDIR}/calls"
  mkdir -p "${ST}"; : > "${CALLS}"
  export PATH="${BATS_TEST_DIRNAME}/stubs/egress:${PATH}" PERSIST=0
  unset EGRESS_NO_DOCKER_USER EGRESS_NO_FORWARD_JUMP EGRESS_FORWARD_ACCEPT_FIRST
}

install_policy() { bash "${BATS_TEST_DIRNAME}/../scripts/setup-egress-policy.sh"; }

assert_no_mutation() {
  if grep -Eq '^-(A|D|F|I|N|R|X) ' "${CALLS}"; then
    echo 'Firewall was modified after a failed preflight' >&2
    return 1
  fi
}

@test "missing DOCKER-USER fails before changing rules" {
  export EGRESS_NO_DOCKER_USER=1
  run install_policy
  [ "${status}" -ne 0 ]
  [[ "${output}" == *'DOCKER-USER chain is missing'* ]]
  assert_no_mutation
}

@test "disconnected DOCKER-USER fails before changing rules" {
  export EGRESS_NO_FORWARD_JUMP=1
  run install_policy
  [ "${status}" -ne 0 ]
  [[ "${output}" == *'FORWARD does not jump'* ]]
  assert_no_mutation
}

@test "an earlier FORWARD accept fails before changing rules" {
  export EGRESS_FORWARD_ACCEPT_FIRST=1
  run install_policy
  [ "${status}" -ne 0 ]
  [[ "${output}" == *'first unconditional FORWARD rule'* ]]
  assert_no_mutation
}

@test "installs jumps first and reruns without duplicate jumps" {
  run install_policy
  [ "${status}" -eq 0 ]
  grep -qx -- '-A DOCKER-USER -j INFRA-RUNNER-FWD' "${ST}/user_first"
  grep -qx -- '-A INPUT -j INFRA-RUNNER-IN' "${ST}/input_first"
  [ "$(grep -c '^-I DOCKER-USER' "${CALLS}")" -eq 1 ]
  [ "$(grep -c '^-I INPUT' "${CALLS}")" -eq 1 ]

  run install_policy
  [ "${status}" -eq 0 ]
  [ "$(grep -c '^-I DOCKER-USER' "${CALLS}")" -eq 1 ]
  [ "$(grep -c '^-I INPUT' "${CALLS}")" -eq 1 ]
}
