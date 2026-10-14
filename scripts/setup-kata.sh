#!/bin/bash
# Install Kata for runner containers without changing Docker's default runc runtime.
# Run as root on the Linux host. Existing containers are not recreated.
set -euo pipefail

VERSION=4.2.0
SHA256=b828904fa3f1e49ddd7dc799c72cb1503cd1e772d354c3987c8d4189b2a623a8
URL="https://github.com/kata-containers/kata-containers/releases/download/${VERSION}/kata-static-${VERSION}-amd64.tar.zst"
SHIM=/opt/kata/runtime-rs/bin/containerd-shim-kata-v2
CONFIG=/opt/kata/share/defaults/kata-containers/runtime-rs/configuration-qemu-runtime-rs.toml
SMOKE_IMAGE="${KATA_SMOKE_IMAGE:-ubuntu:24.04}"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ "$(id -u)" == 0 ]] || fail 'run as root'
[[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || fail 'requires Linux x86_64'
for cmd in curl jq sha256sum tar zstd docker systemctl modprobe; do
  command -v "${cmd}" > /dev/null || fail "missing command: ${cmd}"
done
[[ -c /dev/kvm ]] || fail '/dev/kvm is unavailable'
modprobe vhost_vsock
[[ -c /dev/vhost-vsock ]] || fail '/dev/vhost-vsock is unavailable'
[[ "$(stat -fc %T /sys/fs/cgroup)" == cgroup2fs ]] || fail 'cgroup v2 is required'
docker_major=$(docker version --format '{{.Server.Version}}' | cut -d. -f1)
if [[ ! "${docker_major}" =~ ^[0-9]+$ ]] || (( docker_major < 26 )); then
  fail 'Docker Engine 26 or newer is required'
fi

work=$(mktemp -d /tmp/infra-runner-kata.XXXXXXXX)
stage=$(mktemp -d /opt/.infra-runner-kata.XXXXXXXX)
trap 'rm -rf "${work}" "${stage}"' EXIT
if [[ -e /opt/kata ]]; then
  [[ -x "${SHIM}" && -f "${CONFIG}" ]] || fail '/opt/kata is incomplete or incompatible'
  [[ -f /opt/kata/.infra-runner-version ]] \
    || fail '/opt/kata was installed outside this script; inspect it before changing Docker'
  [[ "$(cat /opt/kata/.infra-runner-version)" == "${VERSION}" ]] \
    || fail 'installed Kata version differs; drain Kata containers and plan a separate upgrade'
  echo "Kata ${VERSION} already installed."
else
  if [[ -n "${KATA_ARCHIVE:-}" ]]; then
    [[ -f "${KATA_ARCHIVE}" ]] || fail "archive does not exist: ${KATA_ARCHIVE}"
    cp "${KATA_ARCHIVE}" "${work}/kata.tar.zst"
  else
    echo "Downloading Kata ${VERSION}..."
    curl -fL --retry 3 "${URL}" -o "${work}/kata.tar.zst"
  fi
  echo "${SHA256}  ${work}/kata.tar.zst" | sha256sum -c -
  tar --use-compress-program=zstd -xf "${work}/kata.tar.zst" -C "${stage}"
  [[ -x "${stage}/opt/kata/runtime-rs/bin/containerd-shim-kata-v2" ]] \
    || fail 'release archive has no Rust shim'
  [[ -f "${stage}/opt/kata/share/defaults/kata-containers/runtime-rs/configuration-qemu-runtime-rs.toml" ]] \
    || fail 'release archive has no Rust QEMU configuration'
  printf '%s\n' "${VERSION}" > "${stage}/opt/kata/.infra-runner-version"
  mv "${stage}/opt/kata" /opt/kata
fi

mkdir -p /etc/docker
daemon=/etc/docker/daemon.json
[[ -f "${daemon}" ]] || printf '{}\n' > "${daemon}"
jq -e 'type == "object" and ((.runtimes // {}) | type == "object")' "${daemon}" > /dev/null \
  || fail "${daemon} is not a valid Docker daemon configuration"
jq --arg shim "${SHIM}" --arg config "${CONFIG}" \
  '.runtimes = ((.runtimes // {}) + {kata: {runtimeType: $shim, options: {ConfigPath: $config}}})' \
  "${daemon}" > "${work}/daemon.json"
if ! cmp -s "${daemon}" "${work}/daemon.json"; then
  dockerd --validate --config-file "${work}/daemon.json" > /dev/null \
    || fail 'Docker rejected the proposed daemon configuration'
  cp -p "${daemon}" "${daemon}.infra-runner-backup-$(date +%Y%m%d%H%M%S)"
  install -m 0644 "${work}/daemon.json" "${daemon}"
  systemctl reload docker || fail 'Docker reload failed; do not restart Docker outside a maintenance window'
fi

docker info --format '{{json .Runtimes}}' | jq -e 'has("kata")' > /dev/null \
  || fail 'Docker did not load the kata runtime; plan a maintenance window before restarting Docker'
[[ "$(docker info --format '{{.DefaultRuntime}}')" == runc ]] \
  || fail 'Docker default runtime changed from runc'
if [[ -x /opt/kata/bin/kata-runtime ]]; then
  /opt/kata/bin/kata-runtime check --no-network-checks
fi
docker image inspect "${SMOKE_IMAGE}" > /dev/null \
  || fail "smoke image ${SMOKE_IMAGE} is absent; pull it explicitly and rerun"
host_kernel=$(uname -r)
guest_kernel=$(docker run --rm --pull never --runtime kata "${SMOKE_IMAGE}" uname -r) \
  || fail 'Kata smoke container failed'
[[ "${guest_kernel}" != "${host_kernel}" ]] || fail 'guest kernel matches host kernel'
printf "PASS: Kata ${VERSION}, Docker default runc, guest kernel %s (host %s)\n" \
  "${guest_kernel}" "${host_kernel}"
