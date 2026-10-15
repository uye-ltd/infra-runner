#!/bin/bash
# setup-egress-policy.sh
#
# One-time setup script (idempotent — safe to re-run). Run as root on the server.
#
# Restricts traffic from runner job networks (RUNNER_SUBNET, default 10.89.0.0/16 — the
# controller creates every per-job network with an explicit /24 from this range):
#
#   FORWARD (via DOCKER-USER → INFRA-RUNNER-FWD)
#     - private, link-local (cloud metadata) and CGNAT ranges: DROP (no lateral movement)
#     - DNS (53) and HTTPS (443) to the internet: allowed
#     - everything else: DROP
#   INPUT (→ INFRA-RUNNER-IN)
#     - traffic from runners to the HOST itself (its gateway / public IPs — sshd, published
#       ports, anything listening on 0.0.0.0): DROP, except DNS to a host-local resolver
#
# The rules live in dedicated chains that this script flushes and refills; it only adds
# jump rules to DOCKER-USER and INPUT, so other rules on the host are left untouched.
# Allowed traffic RETURNs (not ACCEPTs), so Docker's own isolation chains still apply.
#
# Options (env): RUNNER_SUBNET=10.89.0.0/16   PERSIST=1 (install systemd unit)
set -euo pipefail

RUNNER_SUBNET="${RUNNER_SUBNET:-10.89.0.0/16}"
PERSIST="${PERSIST:-1}"
FWD_CHAIN=INFRA-RUNNER-FWD
IN_CHAIN=INFRA-RUNNER-IN
BLOCKED_RANGES=(10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10)

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: must run as root" >&2
  exit 1
fi

# Docker's iptables backend installs this unconditional jump before its own FORWARD
# rules. A manually created DOCKER-USER chain, or one reached after an ACCEPT rule,
# would make the policy appear installed while leaving runner traffic unrestricted.
if ! iptables -L DOCKER-USER -n > /dev/null 2>&1; then
  echo "ERROR: Docker's DOCKER-USER chain is missing. This policy requires Docker's iptables firewall backend; check Docker firewall-backend and start Docker first." >&2
  exit 1
fi
if ! iptables -C FORWARD -j DOCKER-USER > /dev/null 2>&1; then
  echo "ERROR: FORWARD does not jump to DOCKER-USER. Check Docker's iptables firewall backend before installing the policy." >&2
  exit 1
fi
first_forward_rule=$(iptables -S FORWARD | awk '$1 == "-A" && !seen { print; seen = 1 }')
if [[ "${first_forward_rule}" != '-A FORWARD -j DOCKER-USER' ]]; then
  echo "ERROR: DOCKER-USER must be the first unconditional FORWARD rule; an earlier rule can bypass runner egress restrictions." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 0. Migration from earlier versions of this script
# ---------------------------------------------------------------------------
# Earlier versions (a) flushed DOCKER-USER and wrote the rules straight into it and
# (b) set Docker's default-address-pools to the runner range, which also placed every
# OTHER compose network (e.g. plugin networks) under the runner egress rules.

# (a) Remove the exact rules the old version appended to DOCKER-USER (if present).
legacy_rules=(
  "-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
  "-s ${RUNNER_SUBNET} -d 10.0.0.0/8 -j DROP"
  "-s ${RUNNER_SUBNET} -d 172.16.0.0/12 -j DROP"
  "-s ${RUNNER_SUBNET} -d 192.168.0.0/16 -j DROP"
  "-s ${RUNNER_SUBNET} -d 169.254.0.0/16 -j DROP"
  "-s ${RUNNER_SUBNET} -p udp --dport 53 -j ACCEPT"
  "-s ${RUNNER_SUBNET} -p tcp --dport 53 -j ACCEPT"
  "-s ${RUNNER_SUBNET} -p tcp --dport 443 -j ACCEPT"
  "-s ${RUNNER_SUBNET} -j DROP"
)
if iptables -L DOCKER-USER -n > /dev/null 2>&1; then
  for rule in "${legacy_rules[@]}"; do
    # shellcheck disable=SC2086  # rule is a list of iptables arguments
    while iptables -D DOCKER-USER ${rule} 2>/dev/null; do :; done
  done
fi

# (b) Only warn: editing daemon.json requires a Docker restart and recreating networks.
if [[ -f /etc/docker/daemon.json ]] && command -v jq > /dev/null \
   && jq -e --arg s "${RUNNER_SUBNET}" '."default-address-pools"[]? | select(.base == $s)' /etc/docker/daemon.json > /dev/null; then
  cat >&2 <<EOF
WARNING: /etc/docker/daemon.json sets default-address-pools to ${RUNNER_SUBNET} (from an
older version of this script). Docker then allocates EVERY network without an explicit
subnet from the runner range, so those networks are subject to the runner egress rules.
The controller now assigns runner subnets explicitly, so the pool is no longer needed:
  1. remove the "default-address-pools" entry for ${RUNNER_SUBNET} from daemon.json
  2. systemctl restart docker
  3. recreate affected non-runner networks: docker network ls; docker network inspect …
     (e.g. 'docker compose down && docker compose up -d' in the owning project)
EOF
fi

# ---------------------------------------------------------------------------
# 1. FORWARD: runner → elsewhere
# ---------------------------------------------------------------------------
echo "Configuring ${FWD_CHAIN} for ${RUNNER_SUBNET}..."

iptables -N "${FWD_CHAIN}" 2>/dev/null || true
iptables -F "${FWD_CHAIN}"

iptables -A "${FWD_CHAIN}" -s "${RUNNER_SUBNET}" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
for range in "${BLOCKED_RANGES[@]}"; do
  iptables -A "${FWD_CHAIN}" -s "${RUNNER_SUBNET}" -d "${range}" -j DROP
done
iptables -A "${FWD_CHAIN}" -s "${RUNNER_SUBNET}" -p udp --dport 53  -j RETURN
iptables -A "${FWD_CHAIN}" -s "${RUNNER_SUBNET}" -p tcp --dport 53  -j RETURN
# HTTPS only. HTTP (80) and git+ssh (22) are intentionally blocked; to allow git+ssh add
#   iptables -I INFRA-RUNNER-FWD <n> -s <subnet> -p tcp --dport 22 -j RETURN  before the final DROP.
iptables -A "${FWD_CHAIN}" -s "${RUNNER_SUBNET}" -p tcp --dport 443 -j RETURN
iptables -A "${FWD_CHAIN}" -s "${RUNNER_SUBNET}" -j DROP

# Put our jump ahead of any host rules that might ACCEPT runner traffic. If an
# older jump is lower in the chain, the new first jump makes it unreachable.
first_user_rule=$(iptables -S DOCKER-USER | awk '$1 == "-A" && !seen { print; seen = 1 }')
if [[ "${first_user_rule}" != "-A DOCKER-USER -j ${FWD_CHAIN}" ]]; then
  iptables -I DOCKER-USER 1 -j "${FWD_CHAIN}"
fi

# ---------------------------------------------------------------------------
# 2. INPUT: runner → the host itself
# ---------------------------------------------------------------------------
echo "Configuring ${IN_CHAIN} for ${RUNNER_SUBNET}..."

iptables -N "${IN_CHAIN}" 2>/dev/null || true
iptables -F "${IN_CHAIN}"
iptables -A "${IN_CHAIN}" -s "${RUNNER_SUBNET}" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
# DNS: Docker's embedded resolver may forward from the container's namespace to a
# resolver on the host.
iptables -A "${IN_CHAIN}" -s "${RUNNER_SUBNET}" -p udp --dport 53 -j RETURN
iptables -A "${IN_CHAIN}" -s "${RUNNER_SUBNET}" -p tcp --dport 53 -j RETURN
iptables -A "${IN_CHAIN}" -s "${RUNNER_SUBNET}" -j DROP

first_input_rule=$(iptables -S INPUT | awk '$1 == "-A" && !seen { print; seen = 1 }')
if [[ "${first_input_rule}" != "-A INPUT -j ${IN_CHAIN}" ]]; then
  iptables -I INPUT 1 -j "${IN_CHAIN}"
fi

echo "  Rules applied."

# ---------------------------------------------------------------------------
# 3. Reapply after Docker starts and restarts
# ---------------------------------------------------------------------------
if [[ "${PERSIST}" == 1 ]]; then
  echo "Installing systemd egress policy unit..."
  script_path=$(realpath "$0")
  cat > /etc/systemd/system/infra-runner-egress.service <<EOF
[Unit]
Description=Apply infra-runner egress policy after Docker and UFW
Requires=docker.service
After=docker.service ufw.service
PartOf=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=PERSIST=0 RUNNER_SUBNET=${RUNNER_SUBNET}
ExecStart=${script_path}

[Install]
WantedBy=docker.service
EOF
  systemctl daemon-reload
  systemctl enable --now infra-runner-egress.service
  echo "  Enabled infra-runner-egress.service"
fi

cat <<EOF

Done. Runner networks (${RUNNER_SUBNET}) may only reach:
  - DNS   : UDP/TCP 53 (internet, or a resolver on the host)
  - HTTPS : TCP 443 (internet)
Blocked: ${BLOCKED_RANGES[*]}, the host itself, all other ports/protocols.
IPv6 is not covered — the controller explicitly disables it for runner networks.
EOF
