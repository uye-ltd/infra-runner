#!/bin/bash
# setup-apparmor.sh
#
# One-time setup script. Run as root on the server before starting the stack.
#
# Installs and loads the AppArmor profile for runner containers. The profile
# restricts capabilities, network socket types, and access to sensitive host
# paths while allowing the broad filesystem access CI workflows require.
#
# The controller passes --security-opt apparmor=infra-runner to every spawned
# runner container. Set RUNNER_APPARMOR_PROFILE= (empty) in .env to disable.
set -euo pipefail

PROFILE_SRC="$(cd "$(dirname "$0")/.." && pwd)/apparmor/infra-runner"
PROFILE_DST="/etc/apparmor.d/infra-runner"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: must run as root" >&2
  exit 1
fi

if ! command -v apparmor_parser &>/dev/null; then
  echo "Installing apparmor..."
  apt-get install -y -q apparmor apparmor-utils
fi

echo "Installing AppArmor profile..."
cp "${PROFILE_SRC}" "${PROFILE_DST}"

echo "Loading profile..."
apparmor_parser -r -W "${PROFILE_DST}"

echo
echo "Profile loaded: infra-runner"
echo "Verify with: aa-status | grep infra-runner"
