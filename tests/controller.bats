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

@test "exited runner is removed and deregistered (404 tolerated)" {
  gh_runners ''
  touch "${ST}/no_image"
  echo 'zz|55|Exited (1) 3 seconds ago' > "${ST}/exited"
  reconcile_rc
  [ "${rc}" -eq 0 ]
  grep -q 'docker rm -f runner-job-zz' "${CALLS}"
  grep -q 'actions/runners/55$' "${CALLS}"
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

@test "shutdown in idle mode removes idle runners and keeps busy ones" {
  running 'runner-job-a|a|1' 'runner-job-b|b|2'
  gh_runners '{"name":"runner-job-a","busy":false,"id":1},{"name":"runner-job-b","busy":true,"id":2}'
  remove_running_runners idle > /dev/null
  grep -q 'rm -f runner-job-a' "${CALLS}"
  refute grep -q 'rm -f runner-job-b' "${CALLS}"
}

@test "job networks get explicit /24s in RUNNER_SUBNET_PREFIX and move on overlap" {
  gh_runners ''
  echo 2 > "${ST}/overlaps"
  DESIRED_IDLE=1; MAX_RUNNERS=1
  reconcile_rc
  [ "${rc}" -eq 0 ]
  [ "$(grep -c 'network create' "${CALLS}")" -eq 3 ]
  [ "$(grep -o 'subnet 10\.89\.[0-9]*\.0/24' "${CALLS}" | sort -u | wc -l)" -eq 3 ]
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
}
