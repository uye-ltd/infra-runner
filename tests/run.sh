#!/bin/bash
# Run the test suite in a container (identical locally and in CI):
#   bats  tests/*.bats                 — controller + deployer logic against stubbed docker/cosign/curl
#   python3 -m unittest tests/test_*.py — deployer health server
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE=infra-runner-tests:local

docker build -q -t "${IMAGE}" -f "${REPO_ROOT}/tests/Dockerfile" "${REPO_ROOT}/tests" > /dev/null
docker run --rm -v "${REPO_ROOT}:/repo:ro" -e PYTHONDONTWRITEBYTECODE=1 -e BATS_TEST_TIMEOUT=60 "${IMAGE}" bash -c '
  set -e
  bats --print-output-on-failure tests/
  python3 -m unittest discover -s tests -p "test_*.py" -v
'
