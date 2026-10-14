#!/usr/bin/env bats
# controller/entrypoint.sh — reconcile logic against stubbed docker / GitHub API.
#
# The entrypoint is sourced (main() only runs when executed), so each test calls the
# functions directly. reconcile() is invoked as `if reconcile`, exactly like main(),
# because production relies on errexit being ignored inside it.

# `! cmd` does NOT fail a bats test (bash ignores errexit for negated commands);
# use refute for every negative assertion.
refute() { if "$@"; then echo "refute: unexpectedly succeeded: $*" >&2; return 1; fi; }

setup() {
  export ST="${BATS_TEST_TMPDIR}/state" CALLS="${BATS_TEST_TMPDIR}/calls"
  mkdir -p "${ST}"; : > "${CALLS}"
  export PATH="${BATS_TEST_DIRNAME}/stubs/controller:${PATH}"
  export GITHUB_ORG=acme RUNNER_IMAGE=img:verified GITHUB_TOKEN=pat \
         SCRIPTS_DIR="${BATS_TEST_DIRNAME}/../scripts" DESIRED_IDLE=2 MAX_RUNNERS=4 \
         HEARTBEAT_FILE="${BATS_TEST_TMPDIR}/heartbeat"
  # shellcheck source=controller/entrypoint.sh
  source "${BATS_TEST_DIRNAME}/../controller/entrypoint.sh"
  set +u   # bats internals are not nounset-clean
}

gh_runners() { echo "{\"runners\":[$1]}" > "${ST}/gh_runners"; }
running()    { printf '%s\n' "$@" > "${ST}/running"; }
reconcile_rc() { if reconcile > /dev/null 2>&1; then rc=0; else rc=$?; fi; }
calls()      { cat "${CALLS}"; }

@test "spawns one JIT runner when one runner is idle and one busy" {
  running 'runner-job-a|a|' 'runner-job-b|b|'
  gh_runners '{"name":"runner-job-a","busy":false,"id":1},{"name":"runner-job-b","busy":true,"id":2},{"name":"other","busy":true,"id":3}'
  reconcile_rc
  [ "${rc}" -eq 0 ]
  [ "$(grep -c '^docker run' "${CALLS}")" -eq 1 ]
  grep -q -- '--pull never' "${CALLS}"
  grep -q -- '--pids-limit=4096' "${CALLS}"
  grep -q 'runner-gh-id=77' "${CALLS}"
  grep -q 'RUNNER_JITCONFIG=JITXYZ' "${CALLS}"
  refute grep -q registration-token "${CALLS}"
}

@test "GitHub API down: no spawn, cycle fails without killing running jobs" {
  touch "${ST}/api_fail"
  running 'runner-job-a|a|' 'runner-job-b|b|'
  reconcile_rc
  [ "${rc}" -eq 1 ]
  refute grep -q '^docker run' "${CALLS}"
  refute grep -q '^docker rm' "${CALLS}"
}

@test "malformed GitHub response cannot mark the cycle healthy or spawn runners" {
  printf '{"message":"partial response"}' > "${ST}/gh_runners"
  reconcile_rc
  [ "${rc}" -eq 1 ]
  refute grep -q '^docker run' "${CALLS}"

  printf '{"runners":[{"name":"runner-job-a","busy":"false","id":1}]}' > "${ST}/gh_runners"
  reconcile_rc
  [ "${rc}" -eq 1 ]
  refute grep -q '^docker run' "${CALLS}"
}

@test "GitHub App token must be a nonempty string" {
  source "${BATS_TEST_DIRNAME}/../scripts/github-app-token.sh"
  _make_jwt() { printf 'fake.jwt'; }
  GITHUB_APP_ID=123 GITHUB_APP_INSTALLATION_ID=456 GITHUB_APP_PRIVATE_KEY_PATH=/unused
  [ "$(generate_installation_token)" = ghs_testtoken ]
  touch "${ST}/app_token_bad"
  if generate_installation_token > /dev/null; then
    echo 'Malformed GitHub App token was accepted' >&2
    return 1
  fi
}

@test "GitHub App JWT has a valid RS256 signature and short lifetime" {
  source "${BATS_TEST_DIRNAME}/../scripts/github-app-token.sh"
  local key="${BATS_TEST_TMPDIR}/app.pem" jwt
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "${key}" > /dev/null 2>&1
  jwt=$(_make_jwt 123 "${key}")
  python3 - "${jwt}" "${BATS_TEST_TMPDIR}" <<'PY'
import base64
import json
from pathlib import Path
import sys
import time

header, payload, signature = sys.argv[1].split('.')
decode = lambda part: base64.urlsafe_b64decode(part + '=' * (-len(part) % 4))
assert json.loads(decode(header)) == {'alg': 'RS256', 'typ': 'JWT'}
claims = json.loads(decode(payload))
now = time.time()
assert claims['iss'] == '123'
assert now - 120 <= claims['iat'] <= now
assert now < claims['exp'] <= now + 600
assert claims['exp'] - claims['iat'] == 600
Path(sys.argv[2], 'signed').write_bytes(f'{header}.{payload}'.encode())
Path(sys.argv[2], 'signature').write_bytes(decode(signature))
PY
  openssl pkey -in "${key}" -pubout -out "${BATS_TEST_TMPDIR}/app.pub" > /dev/null 2>&1
  openssl dgst -sha256 -verify "${BATS_TEST_TMPDIR}/app.pub" \
    -signature "${BATS_TEST_TMPDIR}/signature" "${BATS_TEST_TMPDIR}/signed" \
    | grep -Fxq 'Verified OK'
}

@test "legacy registration token must be a nonempty string" {
  RUNNER_REGISTRATION_MODE=token
  gh_runners ''
  touch "${ST}/registration_token_bad"
  reconcile_rc
  [ "${rc}" -eq 1 ]
  refute grep -q '^docker run' "${CALLS}"
  grep -q '^docker network rm' "${CALLS}"
}

@test "valid legacy registration token starts an ephemeral runner" {
  RUNNER_REGISTRATION_MODE=token
  DESIRED_IDLE=1; MAX_RUNNERS=1
  gh_runners ''
  reconcile_rc
  [ "${rc}" -eq 0 ]
  grep -q 'RUNNER_REGISTRATION_TOKEN=REGXYZ' "${CALLS}"
  refute grep -q 'RUNNER_JITCONFIG=' "${CALLS}"
}

@test "a failed later GitHub page prevents spawning from a partial busy map" {
  jq -nc '{runners: [range(100) | {name: ("runner-job-" + tostring), busy: false, id: .}]}' \
    > "${ST}/gh_runners_page_1"
  touch "${ST}/api_fail_page_2"
  reconcile_rc
  [ "${rc}" -eq 1 ]
  refute grep -q '^docker run' "${CALLS}"
}

@test "MAX_RUNNERS caps the pool even when no runner is idle" {
  running 'runner-job-a|a|' 'runner-job-b|b|' 'runner-job-c|c|' 'runner-job-d|d|'
  gh_runners '{"name":"runner-job-a","busy":true,"id":1},{"name":"runner-job-b","busy":true,"id":2},{"name":"runner-job-c","busy":true,"id":3},{"name":"runner-job-d","busy":true,"id":4}'
  reconcile_rc
  refute grep -q '^docker run' "${CALLS}"
}

@test "running runner absent from GitHub does not satisfy desired idle capacity" {
  running 'runner-job-a|a|1'
  gh_runners ''
  DESIRED_IDLE=1; MAX_RUNNERS=2
  reconcile_rc
  [ "${rc}" -eq 0 ]
  [ "$(grep -c '^docker run' "${CALLS}")" -eq 1 ]
  refute grep -q 'docker rm -f runner-job-a' "${CALLS}"
}

@test "running runner with a mismatched GitHub ID does not satisfy idle capacity" {
  running 'runner-job-a|a|1'
  gh_runners '{"name":"runner-job-a","busy":false,"id":2}'
  DESIRED_IDLE=1; MAX_RUNNERS=2
  reconcile_rc
  [ "${rc}" -eq 0 ]
  [ "$(grep -c '^docker run' "${CALLS}")" -eq 1 ]
}

@test "exited runner is removed and deregistered (404 tolerated)" {
  DESIRED_IDLE=0
  gh_runners ''
  touch "${ST}/no_image"
  echo 'zz|55|Exited (1) 3 seconds ago' > "${ST}/exited"
  reconcile_rc
  [ "${rc}" -eq 0 ]
  grep -q 'docker rm -f runner-job-zz' "${CALLS}"
  grep -q 'actions/runners/55$' "${CALLS}"
}

@test "failed dead-runner removal fails reconciliation and retries" {
  DESIRED_IDLE=0
  gh_runners ''
  running 'runner-job-a|a|1'
  echo 'zz|55|Exited (1) 3 seconds ago' > "${ST}/exited"
  touch "${ST}/rm_fail"
  reconcile_rc
  [ "${rc}" -eq 1 ]
  grep -q 'docker rm -f runner-job-zz' "${CALLS}"
  rm "${ST}/rm_fail"; : > "${CALLS}"
  reconcile_rc
  [ "${rc}" -eq 0 ]
  grep -q 'docker rm -f runner-job-zz' "${CALLS}"
}

@test "failed orphan-network removal fails reconciliation and retries" {
  DESIRED_IDLE=0
  gh_runners ''
  running 'runner-job-a|a|1'
  echo 'runner-net-zz|zz' > "${ST}/nets"
  touch "${ST}/network_rm_fail"
  reconcile_rc
  [ "${rc}" -eq 1 ]
  grep -q 'docker network rm runner-net-zz' "${CALLS}"
  rm "${ST}/network_rm_fail"; : > "${CALLS}"
  reconcile_rc
  [ "${rc}" -eq 0 ]
  grep -q 'docker network rm runner-net-zz' "${CALLS}"
}

@test "orphaned JIT registration is removed before its network" {
  DESIRED_IDLE=0
  echo 'runner-net-aabbccddee|aabbccddee' > "${ST}/nets"
  gh_runners '{"name":"runner-job-aabbccddee","busy":false,"id":88},{"name":"runner-job-other","busy":false,"id":99}'
  reconcile_rc
  [ "${rc}" -eq 0 ]
  local delete_line network_line
  delete_line=$(grep -n 'actions/runners/88$' "${CALLS}" | head -1 | cut -d: -f1)
  network_line=$(grep -n 'docker network rm runner-net-aabbccddee' "${CALLS}" | head -1 | cut -d: -f1)
  [ "${delete_line}" -lt "${network_line}" ]
  refute grep -q 'actions/runners/99$' "${CALLS}"
}

@test "failed orphaned JIT deregistration preserves the network for retry" {
  DESIRED_IDLE=0
  echo 'runner-net-aabbccddee|aabbccddee' > "${ST}/nets"
  gh_runners '{"name":"runner-job-aabbccddee","busy":false,"id":88}'
  touch "${ST}/delete_fail"
  reconcile_rc
  [ "${rc}" -eq 1 ]
  refute grep -q 'docker network rm runner-net-aabbccddee' "${CALLS}"
  rm "${ST}/delete_fail"; : > "${CALLS}"
  reconcile_rc
  [ "${rc}" -eq 0 ]
  grep -q 'actions/runners/88$' "${CALLS}"
  grep -q 'docker network rm runner-net-aabbccddee' "${CALLS}"
}

@test "GitHub API outage preserves orphaned network for registration cleanup" {
  DESIRED_IDLE=0
  echo 'runner-net-aabbccddee|aabbccddee' > "${ST}/nets"
  touch "${ST}/api_fail"
  reconcile_rc
  [ "${rc}" -eq 1 ]
  refute grep -q 'docker network rm runner-net-aabbccddee' "${CALLS}"
}

@test "fresh job network is not cleaned while runner creation may still be active" {
  DESIRED_IDLE=0
  gh_runners '{"name":"runner-job-aabbccddee","busy":false,"id":88}'
  echo "runner-net-aabbccddee|aabbccddee|$(date +%s)" > "${ST}/nets"
  reconcile_rc
  [ "${rc}" -eq 0 ]
  refute grep -q 'actions/runners/88$' "${CALLS}"
  refute grep -q 'docker network rm runner-net-aabbccddee' "${CALLS}"
  echo "runner-net-aabbccddee|aabbccddee|$(( $(date +%s) - 121 ))" > "${ST}/nets"
  reconcile_rc
  [ "${rc}" -eq 0 ]
  grep -q 'actions/runners/88$' "${CALLS}"
  grep -q 'docker network rm runner-net-aabbccddee' "${CALLS}"
}

@test "failed GitHub deregistration fails reconciliation and retries" {
  DESIRED_IDLE=0
  gh_runners ''
  echo 'zz|55|Exited (1) 3 seconds ago' > "${ST}/exited"
  touch "${ST}/delete_fail"
  reconcile_rc
  [ "${rc}" -eq 1 ]
  grep -q 'actions/runners/55$' "${CALLS}"
  refute grep -q 'docker rm -f runner-job-zz' "${CALLS}"
  rm "${ST}/delete_fail"; : > "${CALLS}"
  reconcile_rc
  [ "${rc}" -eq 0 ]
  grep -q 'actions/runners/55$' "${CALLS}"
  grep -q 'docker rm -f runner-job-zz' "${CALLS}"
}

@test "missing verified runner image makes the cycle unhealthy without spawning" {
  gh_runners ''
  touch "${ST}/no_image"
  reconcile_rc
  [ "${rc}" -eq 1 ]
  refute grep -q '^docker run' "${CALLS}"
}

@test "docker unreachable: reconcile fails without killing the shell" {
  touch "${ST}/ps_fail"
  reconcile_rc
  [ "${rc}" -eq 1 ]
}

@test "failed docker run: JIT runner deregistered and spawn backs off" {
  gh_runners ''
  touch "${ST}/run_fail"
  reconcile_rc
  [ "${rc}" -eq 1 ]
  (( _next_spawn_at > $(date +%s) ))
  grep -q 'actions/runners/77$' "${CALLS}"
  rm "${ST}/run_fail"; : > "${CALLS}"
  reconcile_rc
  refute grep -q '^docker run' "${CALLS}"
}

@test "malformed JIT response cannot start an untraceable runner" {
  gh_runners ''
  touch "${ST}/jit_missing_id"
  reconcile_rc
  [ "${rc}" -eq 1 ]
  refute grep -q '^docker run' "${CALLS}"
  grep -q '^docker network rm' "${CALLS}"
}

@test "partial JIT response recovers runner ID by its exact generated name" {
  gh_runners '{"name":"runner-job-aabbccddee","busy":false,"id":88}'
  touch "${ST}/jit_missing_id"
  DESIRED_IDLE=1; MAX_RUNNERS=1
  reconcile_rc
  [ "${rc}" -eq 1 ]
  refute grep -q '^docker run' "${CALLS}"
  grep -q 'actions/runners/88$' "${CALLS}"
}

@test "missing JIT config deregisters the runner ID from the partial response" {
  gh_runners ''
  touch "${ST}/jit_bad_config"
  reconcile_rc
  [ "${rc}" -eq 1 ]
  refute grep -q '^docker run' "${CALLS}"
  grep -q 'actions/runners/77$' "${CALLS}"
}

@test "unexpected JIT runner name does not delete an unrelated runner ID" {
  gh_runners ''
  touch "${ST}/jit_wrong_name"
  reconcile_rc
  [ "${rc}" -eq 1 ]
  refute grep -q '^docker run' "${CALLS}"
  refute grep -q 'actions/runners/77$' "${CALLS}"
}

@test "runner exiting immediately is cleaned up and spawn backs off" {
  gh_runners ''
  touch "${ST}/run_exited"
  reconcile_rc
  [ "${rc}" -eq 1 ]
  grep -q '^docker rm -f runner-job-' "${CALLS}"
  grep -q 'actions/runners/77$' "${CALLS}"
  (( _next_spawn_at > $(date +%s) ))
}

@test "startup inspection failure does not kill a potentially running job" {
  gh_runners ''
  touch "${ST}/inspect_fail"
  reconcile_rc
  [ "${rc}" -eq 1 ]
  grep -q '^docker inspect runner-job-' "${CALLS}"
  refute grep -q '^docker rm -f runner-job-' "${CALLS}"
  refute grep -q 'actions/runners/77$' "${CALLS}"
}

@test "shutdown in idle mode removes idle runners and keeps busy ones" {
  running 'runner-job-a|a|1' 'runner-job-b|b|2'
  gh_runners '{"name":"runner-job-a","busy":false,"id":1},{"name":"runner-job-b","busy":true,"id":2}'
  remove_running_runners idle > /dev/null
  grep -q 'rm -f runner-job-a' "${CALLS}"
  refute grep -q 'rm -f runner-job-b' "${CALLS}"
}

@test "shutdown in idle mode preserves runners absent from GitHub or with another ID" {
  running 'runner-job-a|a|1' 'runner-job-b|b|2' 'runner-job-c|c|3'
  gh_runners '{"name":"runner-job-b","busy":false,"id":9},{"name":"runner-job-c","busy":false,"id":3}'
  remove_running_runners idle > /dev/null
  refute grep -q 'rm -f runner-job-a' "${CALLS}"
  refute grep -q 'rm -f runner-job-b' "${CALLS}"
  grep -q 'rm -f runner-job-c' "${CALLS}"
  refute grep -q 'actions/runners/1$' "${CALLS}"
  refute grep -q 'actions/runners/2$' "${CALLS}"
}

@test "shutdown all removes containers even when GitHub deregistration fails" {
  running 'runner-job-a|a|1'
  touch "${ST}/delete_fail"
  if remove_running_runners all > /dev/null; then
    echo 'Expected cleanup to report failed GitHub deregistration' >&2
    return 1
  fi
  grep -q 'docker rm -f runner-job-a' "${CALLS}"
}

@test "job networks get explicit /24s in RUNNER_SUBNET_PREFIX and move on overlap" {
  gh_runners ''
  echo 2 > "${ST}/overlaps"
  DESIRED_IDLE=1; MAX_RUNNERS=1
  reconcile_rc
  [ "${rc}" -eq 0 ]
  [ "$(grep -c 'network create' "${CALLS}")" -eq 3 ]
  [ "$(grep -o 'subnet 10\.89\.[0-9]*\.0/24' "${CALLS}" | sort -u | wc -l)" -eq 3 ]
  [ "$(grep -c 'network create --driver bridge --ipv6=false' "${CALLS}")" -eq 3 ]
  grep -qE -- '--label runner-created-at=[0-9]+' "${CALLS}"
}

@test "network allocation searches beyond 16 occupied subnets" {
  gh_runners ''
  echo 16 > "${ST}/overlaps"
  DESIRED_IDLE=1; MAX_RUNNERS=1
  reconcile_rc
  [ "${rc}" -eq 0 ]
  [ "$(grep -c 'network create' "${CALLS}")" -eq 17 ]
  [ "$(grep -o 'subnet 10\.89\.[0-9]*\.0/24' "${CALLS}" | sort -u | wc -l)" -eq 17 ]
}

@test "network creation errors other than overlap do not exhaust the subnet pool" {
  gh_runners ''
  touch "${ST}/network_create_fail"
  DESIRED_IDLE=1; MAX_RUNNERS=1
  reconcile_rc
  [ "${rc}" -eq 1 ]
  [ "$(grep -c 'network create' "${CALLS}")" -eq 1 ]
}

@test "runner containers get bounded json-file logs" {
  gh_runners ''
  reconcile_rc
  grep -q -- '--log-driver json-file --log-opt max-size=10m --log-opt max-file=3' "${CALLS}"
}

@test "explicitly empty RUNNER_APPARMOR_PROFILE disables AppArmor" {
  gh_runners ''
  # must be set BEFORE sourcing: the default is applied at source time
  export RUNNER_APPARMOR_PROFILE=""
  source "${BATS_TEST_DIRNAME}/../controller/entrypoint.sh"; set +u
  reconcile_rc
  grep -q '^docker run' "${CALLS}"
  refute grep -q 'apparmor=' "${CALLS}"
}

@test "SIGTERM during the poll sleep exits promptly" {
  gh_runners ''
  CONTROLLER_POLL_INTERVAL=60 DESIRED_IDLE=0 bash "${BATS_TEST_DIRNAME}/../controller/entrypoint.sh" > /dev/null 2>&1 &
  pid=$!
  sleep 2
  start=$(date +%s)
  kill -TERM "${pid}"
  wait "${pid}"
  (( $(date +%s) - start < 5 ))
  [ -s "${HEARTBEAT_FILE}" ]
}

@test "zero poll interval, zero pids limit and invalid subnet fail at startup" {
  local entry="${BATS_TEST_DIRNAME}/../controller/entrypoint.sh"
  run env CONTROLLER_POLL_INTERVAL=0 bash -c 'source "$1"' _ "${entry}"
  [ "${status}" -ne 0 ]
  run env RUNNER_PIDS_LIMIT=0 bash -c 'source "$1"' _ "${entry}"
  [ "${status}" -ne 0 ]
  run env RUNNER_SUBNET_PREFIX=10.999 bash -c 'source "$1"' _ "${entry}"
  [ "${status}" -ne 0 ]
  run env DESIRED_IDLE=08 bash -c 'source "$1"' _ "${entry}"
  [ "${status}" -ne 0 ]
  run env MAX_RUNNERS=257 bash -c 'source "$1"' _ "${entry}"
  [ "${status}" -ne 0 ]
  run env DESIRED_IDLE=3 MAX_RUNNERS=2 bash -c 'source "$1"' _ "${entry}"
  [ "${status}" -ne 0 ]
}
