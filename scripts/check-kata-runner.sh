#!/bin/bash
# Server-only Kata compatibility probe. Usage: check-kata-runner.sh IMAGE:verified
# Uses no GitHub runner registration; overrides the runner image entrypoint.
set -uo pipefail

IMAGE="${1:?usage: check-kata-runner.sh IMAGE:verified}"
MEMORY="${RUNNER_MEMORY:-6g}"
KANIKO_SIZE="${RUNNER_KANIKO_SIZE:-2g}"
CPUS="${RUNNER_CPUS:-2}"
PIDS="${RUNNER_PIDS_LIMIT:-4096}"
APPARMOR="${RUNNER_APPARMOR_PROFILE-infra-runner}"
SECCOMP="${RUNNER_SECCOMP_HOST_PATH-$(cd "$(dirname "$0")/.." && pwd)/seccomp/runner-profile.json}"
PREFIX="${RUNNER_SUBNET_PREFIX:-10.89}"
HOST_IP="${KATA_CHECK_HOST_IP:-10.0.0.1}"
LAN_IP="${KATA_CHECK_LAN_IP:-10.0.0.2}"
SKIP_EGRESS="${KATA_CHECK_SKIP_EGRESS:-0}"
DNS="${RUNNER_KATA_DNS:-1.1.1.1}"
name="kata-check-$$"
network="${name}-net"
failures=0
[[ "$(id -u)" == 0 ]] || { echo 'ERROR: run as root to verify firewall counters' >&2; exit 1; }

report() {
  local label="$1" status="$2" detail="${3:-}"
  printf '%-35s %s %s\n' "${label}" "${status}" "${detail}"
  [[ "${status}" == PASS ]] || failures=$((failures + 1))
}
cleanup() {
  docker rm -f "${name}" > /dev/null 2>&1 || true
  docker network rm "${network}" > /dev/null 2>&1 || true
}
trap cleanup EXIT

command -v docker > /dev/null || { report docker FAIL 'docker is unavailable'; exit 1; }
if [[ "${SKIP_EGRESS}" == 1 ]]; then
  echo 'SKIP: egress isolation checks (KATA_CHECK_SKIP_EGRESS=1); compatibility result is incomplete'
else
  command -v iptables > /dev/null || { report firewall FAIL 'iptables is unavailable'; exit 1; }
  if ! iptables -L INFRA-RUNNER-FWD -n > /dev/null 2>&1 \
     || ! iptables -L INFRA-RUNNER-IN -n > /dev/null 2>&1; then
    report firewall FAIL 'INFRA-RUNNER-FWD/IN chains are missing'
    exit 1
  fi
fi
docker image inspect "${IMAGE}" > /dev/null 2>&1 \
  || { report image FAIL "${IMAGE} must be present locally"; exit 1; }

# Mirror the controller's explicitly subnetted per-job bridge. Find a free /24.
created=false
for (( octet = 255; octet >= 0; octet-- )); do
  if docker network create --driver bridge --ipv6=false \
      --subnet "${PREFIX}.${octet}.0/24" --label kata-check=true "${network}" > /dev/null 2>&1; then
    created=true
    break
  fi
done
[[ "${created}" == true ]] || { report network FAIL 'no free runner subnet'; exit 1; }

security=()
[[ -n "${SECCOMP}" ]] && security+=(--security-opt "seccomp=${SECCOMP}")
[[ -n "${APPARMOR}" ]] && security+=(--security-opt "apparmor=${APPARMOR}")
base=(--rm --pull never --network "${network}"
  --memory="${MEMORY}" --cpus="${CPUS}" --pids-limit="${PIDS}"
  --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER
  --cap-add SETUID --cap-add SETGID --cap-add SYS_PTRACE --cap-add SYS_ADMIN
  --tmpfs '/tmp:rw,nosuid,size=1g' --tmpfs '/root:rw,nosuid,size=512m'
  --tmpfs "/kaniko:rw,nosuid,size=${KANIKO_SIZE}" --device /dev/fuse
  "${security[@]}" --entrypoint /bin/bash "${IMAGE}")
common=(--runtime kata -e "RUNNER_KATA_DNS=${DNS}" "${base[@]}")

runc_start=$(date +%s)
if docker run "${base[@]}" -c 'uname -r' > /dev/null 2>&1; then
  runc_elapsed="$(( $(date +%s) - runc_start ))s"
else
  runc_elapsed=failed
  report 'runc baseline' FAIL 'the same runner flags failed under runc'
fi
start=$(date +%s)
if out=$(docker run "${common[@]}" -c 'uname -r; test -c /dev/fuse; test -w /kaniko' 2>&1); then
  elapsed=$(( $(date +%s) - start ))
  guest_kernel=${out%%$'\n'*}
  if [[ -n "${guest_kernel}" && "${guest_kernel}" != "$(uname -r)" ]]; then
    report 'Kata guest kernel and flags' PASS "kernel=${guest_kernel}; startup=${elapsed}s (runc=${runc_elapsed})"
  else
    report 'Kata guest kernel and flags' FAIL 'kernel matches host'
  fi
  report '/dev/fuse and /kaniko tmpfs' PASS
else
  report 'Kata guest kernel and flags' FAIL "${out:0:500}"
  printf 'Retry with RUNNER_APPARMOR_PROFILE= or RUNNER_SECCOMP_HOST_PATH= to isolate security-option failures.\n' >&2
  exit 1
fi

if out=$(docker run -i "${common[@]}" -s <<'BASH' 2>&1
set -euo pipefail
printf 'nameserver %s\n' "${RUNNER_KATA_DNS}" > /etc/resolv.conf
work=$(mktemp -d /tmp/kata-build.XXXXXX)
trap 'rm -rf "$work"' EXIT
printf 'owner test\n' > "$work/payload"
cat > "$work/Dockerfile" <<'DOCKERFILE'
FROM ubuntu:24.04
COPY --chown=12345:23456 payload /root/payload
RUN test "$(stat -c '%u:%g' /root/payload)" = 12345:23456 && test -r /etc/shadow
DOCKERFILE
buildah build --isolation=chroot --pull=missing -t kata-build-probe:local "$work"
buildah rmi kata-build-probe:local >/dev/null
BASH
); then
  report 'Buildah chroot and fuse-overlayfs' PASS
else
  report 'Buildah chroot and fuse-overlayfs' FAIL "${out: -700}"
fi

if out=$(docker run "${common[@]}" -c 'printf "nameserver %s\n" "$RUNNER_KATA_DNS" > /etc/resolv.conf; curl -fsSL --max-time 15 https://github.com -o /dev/null' 2>&1); then
  report 'public HTTPS' PASS
else
  report 'public HTTPS' FAIL "${out:0:500}"
fi

# Check both failed connections and a matching increase in host DROP counters.
drop_count() {
  local chain="$1" destination="$2"
  iptables -vnxL "${chain}" | awk -v d="${destination}" \
    '$3 == "DROP" && $9 == d { sum += $1 } END { print sum + 0 }'
}
if [[ "${SKIP_EGRESS}" != 1 ]]; then
  host_before=$(drop_count INFRA-RUNNER-IN 0.0.0.0/0)
  if docker run "${common[@]}" -c 'timeout 4 bash -c "</dev/tcp/$1/22"' _ "${HOST_IP}" > /dev/null 2>&1; then
    report 'host access blocked' FAIL "${HOST_IP}:22 was reachable"
  elif (( $(drop_count INFRA-RUNNER-IN 0.0.0.0/0) > host_before )); then
    report 'host access blocked' PASS "${HOST_IP}:22 hit INFRA-RUNNER-IN DROP"
  else
    report 'host access blocked' FAIL "${HOST_IP}:22 failed without an INPUT DROP"
  fi
  lan_before=$(drop_count INFRA-RUNNER-FWD 10.0.0.0/8)
  if docker run "${common[@]}" -c 'timeout 4 bash -c "</dev/tcp/$1/22"' _ "${LAN_IP}" > /dev/null 2>&1; then
    report 'LAN access blocked' FAIL "${LAN_IP}:22 was reachable"
  elif (( $(drop_count INFRA-RUNNER-FWD 10.0.0.0/8) > lan_before )); then
    report 'LAN access blocked' PASS "${LAN_IP}:22 hit INFRA-RUNNER-FWD DROP"
  else
    report 'LAN access blocked' FAIL "${LAN_IP}:22 failed without a FORWARD DROP"
  fi
fi

printf 'Summary: %s failure(s).\n' "${failures}"
(( failures == 0 ))
