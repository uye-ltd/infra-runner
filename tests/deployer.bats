#!/usr/bin/env bats
# deployer/entrypoint.sh — reconcile logic against stubbed docker / cosign.
#
# run_cycle() is invoked as `if run_cycle`, exactly like main(), because production
# relies on errexit being ignored inside it.

R=ghcr.io_acme_

# `! cmd` does NOT fail a bats test (bash ignores errexit for negated commands);
# use refute for every negative assertion.
refute() { if "$@"; then echo "refute: unexpectedly succeeded: $*" >&2; return 1; fi; }

setup() {
  export ST="${BATS_TEST_TMPDIR}/state" CALLS="${BATS_TEST_TMPDIR}/calls"
  export HEALTH_FILE="${BATS_TEST_TMPDIR}/health" PLUGINS_DIR="${BATS_TEST_TMPDIR}/plugins"
  mkdir -p "${ST}" "${PLUGINS_DIR}"; : > "${CALLS}"
  export PATH="${BATS_TEST_DIRNAME}/stubs/deployer:${PATH}"
  export GITHUB_ORG=acme COMPOSE_PROJECT_NAME=infra-runner COMPOSE_PROJECT_DIR=/home/gh/infra-runner \
         SCRIPTS_DIR="${BATS_TEST_DIRNAME}/../scripts" SELF_UPDATE_TIMEOUT=9 GITHUB_TOKEN=ghp_SECRET
  # shellcheck source=deployer/entrypoint.sh
  source "${BATS_TEST_DIRNAME}/../deployer/entrypoint.sh"
  set +u
  ensure_health_server() { :; }   # no python server in unit tests
  echo "ghcr.io/acme/uye-deployer:verified"            > "${ST}/svcref_deployer"
  echo "ghcr.io/acme/infra-runner-controller:verified" > "${ST}/svcref_controller"
}

sig()     { echo "$2" > "${ST}/sig_${R}$1"; }        # sig <image name> <digest|BAD|NET>
running() { echo "$2" > "${ST}/ctr_$1"; }            # running <service> <image id>
have()    { echo "id-$2" > "${ST}/img_${R}$1_$(tr ':' '_' <<< "$2")"; }  # have <name> <sha256:x>
verified(){ echo "$2" > "${ST}/img_${R}$1_verified"; }
cycle()   { if run_cycle > /dev/null 2>&1; then :; fi; }
hstatus() { jq -r .status "${HEALTH_FILE}"; }
hreason() { jq -r .reason "${HEALTH_FILE}"; }

# deployer already on the verified d1, runner signed
baseline() {
  sig uye-deployer sha256:d1; have uye-deployer sha256:d1; verified uye-deployer id-sha256:d1
  running deployer id-sha256:d1
  sig infra-runner sha256:r1
}

@test "new controller digest: pulled by digest, tagged, controller recreated" {
  baseline
  sig infra-runner-controller sha256:c2; running controller id-sha256:c1
  cycle
  grep -q 'docker pull --quiet ghcr.io/acme/infra-runner-controller@sha256:c2' "${CALLS}"
  refute grep -qE 'docker pull .*:latest' "${CALLS}"
  grep -q 'tag ghcr.io/acme/infra-runner-controller@sha256:c2 ghcr.io/acme/infra-runner-controller:verified' "${CALLS}"
  grep -q 'tag ghcr.io/acme/infra-runner-controller@sha256:c2 ghcr.io/acme/infra-runner-controller:latest' "${CALLS}"
  [ "$(cat "${ST}/ctr_controller")" = id-sha256:c2 ]
  refute grep -q '^docker run' "${CALLS}"      # deployer itself up to date → no self-update
  grep -q 'infra-runner@sha256:r1' "${CALLS}"
  [ "$(hstatus)" = ok ]
}

@test "bad signature: nothing pulled, running controller untouched, 503" {
  baseline
  sig infra-runner-controller BAD; verified infra-runner-controller id-old; running controller id-old
  cycle
  refute grep -q 'pull .*controller' "${CALLS}"
  refute grep -q 'docker compose' "${CALLS}"
  [ "$(hstatus)" = unhealthy ]
  hreason | grep -q 'Signature verification FAILED for ghcr.io/acme/infra-runner-controller'
}

@test "network error during verification has a distinct reason" {
  sig uye-deployer NET; sig infra-runner-controller sha256:c1; sig infra-runner sha256:r1
  running controller id-sha256:c1
  cycle
  hreason | grep -q 'Sigstore unreachable'
}

@test "running image differs from :verified (e.g. after a restart): applied without a new digest" {
  baseline
  sig infra-runner-controller sha256:c2; have infra-runner-controller sha256:c2; running controller id-sha256:c1
  cycle
  refute grep -q 'pull .*controller' "${CALLS}"
  grep -q 'compose .*up -d --no-deps controller' "${CALLS}"
  [ "$(hstatus)" = ok ]
}

@test "compose up failure: 503, retried and recovered next cycle" {
  baseline
  sig infra-runner-controller sha256:c2; running controller id-sha256:c1
  touch "${ST}/compose_fail"
  cycle
  [ "$(hstatus)" = unhealthy ]
  rm "${ST}/compose_fail"
  cycle
  [ "$(cat "${ST}/ctr_controller")" = id-sha256:c2 ]
  [ "$(hstatus)" = ok ]
}

@test "compose image ref that does not resolve to :verified is reported" {
  baseline
  sig infra-runner-controller sha256:c2; running controller id-x
  echo id-other > "${ST}/img_${R}infra-runner-controller_other"
  echo "ghcr.io/acme/infra-runner-controller:other" > "${ST}/svcref_controller"
  cycle
  hreason | grep -q 'still not running on the verified image'
}

@test "stopped controller is recreated even when its old image matches verified" {
  baseline
  sig infra-runner-controller sha256:c1; have infra-runner-controller sha256:c1
  verified infra-runner-controller id-sha256:c1
  running controller id-sha256:c1
  touch "${ST}/stopped_controller"
  cycle
  grep -q 'compose .*up -d --no-deps controller' "${CALLS}"
  [ ! -f "${ST}/stopped_controller" ]
  [ "$(hstatus)" = ok ]
}

@test "controller inspect failure after compose up stays unhealthy" {
  baseline
  sig infra-runner-controller sha256:c2; running controller id-sha256:c1
  touch "${ST}/inspect_fail_after_compose_controller"
  cycle
  [ "$(hstatus)" = unhealthy ]
  hreason | grep -q 'Cannot inspect the controller container after compose up'
}

@test "controller compose success without a running container stays unhealthy" {
  baseline
  sig infra-runner-controller sha256:c2; running controller id-sha256:c1
  touch "${ST}/compose_stopped_controller"
  cycle
  [ "$(hstatus)" = unhealthy ]
  hreason | grep -q 'still not running on the verified image'
}

@test "self-update helper failing fast is detected quickly and the cycle continues" {
  sig uye-deployer sha256:d2; running deployer id-sha256:d1
  sig infra-runner-controller sha256:c1; have infra-runner-controller sha256:c1; running controller id-sha256:c1
  sig infra-runner sha256:r1
  echo 1 > "${ST}/helper_exit"
  start=$(date +%s)
  cycle
  (( $(date +%s) - start < 8 ))
  grep -q -- '--entrypoint docker ghcr.io/acme/uye-deployer:verified compose --project-name infra-runner --project-directory /home/gh/infra-runner up -d --no-deps deployer' "${CALLS}"
  hreason | grep -q 'Self-update helper failed (exit 1)'
  grep -q 'cosign ghcr.io/acme/infra-runner-controller:latest' "${CALLS}"
}

@test "self-update helper mounts only the project and COMPOSE_FILE directories" {
  export COMPOSE_FILE="docker-compose.yml:docker-compose.override.yml:../infra-vault/docker-compose.infra-runner.yml"
  helper_mounts
  m="${_mounts[*]}"
  [[ "${m}" == *"-v /home/gh/infra-runner:/home/gh/infra-runner:ro"* ]]
  [[ "${m}" == *"-v /home/gh/infra-vault:/home/gh/infra-vault:ro"* ]]
  [ "${#_mounts[@]}" -eq 4 ]
}

plugin_fixture() {
  baseline
  sig infra-runner-controller sha256:c1; have infra-runner-controller sha256:c1; running controller id-sha256:c1
  sig vault-unseal sha256:v2
  mkdir -p "${BATS_TEST_TMPDIR}/pw"
  export VAULT_CERT_IDENTITY=https://id VAULT_TOKEN=hvs.x PLUGIN_HOOK_TIMEOUT=2
  cat > "${PLUGINS_DIR}/v.plugin" <<EOF
# comment
PLUGIN_NAME=vault-unseal
PLUGIN_IMAGE=ghcr.io/\${GITHUB_ORG}/vault-unseal:latest
PLUGIN_CERT_IDENTITY="\${VAULT_CERT_IDENTITY}"   # trailing comment
PLUGIN_COMPOSE_PROJECT=infra-vault
PLUGIN_COMPOSE_DIR=${BATS_TEST_TMPDIR}/pw
export PLUGIN_COMPOSE_SERVICE=vault-unseal
PLUGIN_EVIL=\$(touch ${BATS_TEST_TMPDIR}/pwned)
PLUGIN_POST_DEPLOY_0_SCRIPT=\$(touch ${BATS_TEST_TMPDIR}/pwned2).sh
PLUGIN_POST_DEPLOY_1_SCRIPT=env.sh
PLUGIN_POST_DEPLOY_1_RUN=always
EOF
  echo "env > ${BATS_TEST_TMPDIR}/hook_env" > "${BATS_TEST_TMPDIR}/pw/env.sh"
  echo "ghcr.io/acme/vault-unseal:latest" > "${ST}/svcref_vault-unseal"
  running vault-unseal id-old
}

@test "plugin descriptor is parsed as data: command substitution never runs" {
  plugin_fixture
  cycle
  [ ! -e "${BATS_TEST_TMPDIR}/pwned" ]
  [ ! -e "${BATS_TEST_TMPDIR}/pwned2" ]
  grep -q 'pull --quiet ghcr.io/acme/vault-unseal@sha256:v2' "${CALLS}"
  [ "$(cat "${ST}/ctr_vault-unseal")" = id-sha256:v2 ]
}

@test "plugin on_update hook waits for a verified running service after inspection fails" {
  plugin_fixture
  sed -i 's|^PLUGIN_POST_DEPLOY_0_SCRIPT=.*|PLUGIN_POST_DEPLOY_0_SCRIPT=update.sh|' "${PLUGINS_DIR}/v.plugin"
  echo "touch ${BATS_TEST_TMPDIR}/update_hook_ran" > "${BATS_TEST_TMPDIR}/pw/update.sh"
  touch "${ST}/inspect_fail_after_compose_vault-unseal"
  cycle
  [ "$(hstatus)" = unhealthy ]
  hreason | grep -q 'cannot inspect service after compose up'
  [ ! -e "${BATS_TEST_TMPDIR}/update_hook_ran" ]
  rm "${ST}/inspect_fail_after_compose_vault-unseal"
  cycle
  [ "$(hstatus)" = ok ]
  [ -e "${BATS_TEST_TMPDIR}/update_hook_ran" ]
}

@test "plugin compose success without a running service stays unhealthy" {
  plugin_fixture
  touch "${ST}/compose_stopped_vault-unseal"
  cycle
  [ "$(hstatus)" = unhealthy ]
  hreason | grep -q 'still not running on the verified image'
}

@test "stopped plugin service is recreated even when its image matches verified" {
  plugin_fixture
  have vault-unseal sha256:v2; verified vault-unseal id-sha256:v2
  running vault-unseal id-sha256:v2
  touch "${ST}/stopped_vault-unseal"
  cycle
  grep -q 'compose .*up -d --no-deps vault-unseal' "${CALLS}"
  [ ! -f "${ST}/stopped_vault-unseal" ]
}

@test "plugin hooks never receive GitHub credentials (legacy full-env mode)" {
  plugin_fixture
  cycle
  [ -f "${BATS_TEST_TMPDIR}/hook_env" ]
  refute grep -q GITHUB_TOKEN "${BATS_TEST_TMPDIR}/hook_env"
  grep -q VAULT_TOKEN=hvs.x "${BATS_TEST_TMPDIR}/hook_env"
}

@test "PLUGIN_HOOK_ENV restricts hooks to the listed variables" {
  plugin_fixture
  export PLUGIN_HOOK_ENV="VAULT_TOKEN"
  cycle
  grep -q VAULT_TOKEN "${BATS_TEST_TMPDIR}/hook_env"
  refute grep -q VAULT_CERT_IDENTITY "${BATS_TEST_TMPDIR}/hook_env"
  refute grep -q GITHUB_ORG "${BATS_TEST_TMPDIR}/hook_env"
}

@test "explicit hook allowlist cannot pass GitHub credentials" {
  plugin_fixture
  export GITHUB_APP_PRIVATE_KEY_PATH=/secret/key.pem
  export PLUGIN_HOOK_ENV="GITHUB_TOKEN,GITHUB_APP_PRIVATE_KEY_PATH,VAULT_TOKEN"
  cycle
  [ -f "${BATS_TEST_TMPDIR}/hook_env" ]
  grep -q VAULT_TOKEN=hvs.x "${BATS_TEST_TMPDIR}/hook_env"
  refute grep -q GITHUB_TOKEN "${BATS_TEST_TMPDIR}/hook_env"
  refute grep -q GITHUB_APP_PRIVATE_KEY_PATH "${BATS_TEST_TMPDIR}/hook_env"
}

@test "missing required plugin field marks health unhealthy" {
  plugin_fixture
  sed -i '/^PLUGIN_IMAGE=/d' "${PLUGINS_DIR}/v.plugin"
  cycle
  [ "$(hstatus)" = unhealthy ]
  hreason | grep -q 'missing required field PLUGIN_IMAGE'
}

@test "invalid plugin name marks health unhealthy" {
  plugin_fixture
  sed -i 's/^PLUGIN_NAME=.*/PLUGIN_NAME=bad name/' "${PLUGINS_DIR}/v.plugin"
  cycle
  [ "$(hstatus)" = unhealthy ]
  hreason | grep -q 'Invalid PLUGIN_NAME'
}

@test "duplicate plugin names mark health unhealthy" {
  plugin_fixture
  cp "${PLUGINS_DIR}/v.plugin" "${PLUGINS_DIR}/w.plugin"
  cycle
  [ "$(hstatus)" = unhealthy ]
  hreason | grep -q 'Duplicate PLUGIN_NAME vault-unseal'
}

@test "a hanging non-blocking hook is killed by its timeout" {
  plugin_fixture
  cat >> "${PLUGINS_DIR}/v.plugin" <<'EOF'
PLUGIN_POST_DEPLOY_2_SCRIPT=hang.sh
PLUGIN_POST_DEPLOY_2_RUN=always
PLUGIN_POST_DEPLOY_2_BLOCKING=false
EOF
  echo 'sleep 30' > "${BATS_TEST_TMPDIR}/pw/hang.sh"
  start=$(date +%s)
  cycle
  (( $(date +%s) - start < 10 ))
}
