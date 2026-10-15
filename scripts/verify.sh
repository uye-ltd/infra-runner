#!/bin/bash
# Run the same repository checks locally and in CI.
# Usage: bash scripts/verify.sh [all|lint|test|syntax]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${REPO_ROOT}"

SHELLCHECK_IMAGE=koalaman/shellcheck:v0.10.0@sha256:2097951f02e735b613f4a34de20c40f937a6c8f18ecb170612c88c34517221fb
HADOLINT_IMAGE=hadolint/hadolint:v2.12.0@sha256:30a8fd2e785ab6176eed53f74769e04f125afb2f74a6c52aef7d463583b6d45e
ACTIONLINT_IMAGE=rhysd/actionlint:1.7.7@sha256:887a259a5a534f3c4f36cb02dca341673c6089431057242cdc931e9f133147e9
ZIZMOR_IMAGE=ghcr.io/zizmorcore/zizmor:1.11.0@sha256:732696b82d9010ea395085f1b620d834ab87c26e6696f46227755bf4bc1ad3f7

syntax() {
  local file
  for file in entrypoint.sh controller/entrypoint.sh deployer/entrypoint.sh scripts/*.sh tests/run.sh tests/stubs/*/*; do
    bash -n "${file}"
  done
  python3 -B - <<'PY'
from pathlib import Path

for path in (Path("deployer/health_server.py"), Path("deployer/poller.py"),
             Path("tests/test_health_server.py"), Path("tests/test_poller.py")):
    compile(path.read_bytes(), str(path), "exec")
PY
}

lint() {
  syntax
  docker run --rm -v "${REPO_ROOT}:/mnt:ro" -w /mnt "${SHELLCHECK_IMAGE}" -x -P scripts \
    entrypoint.sh controller/entrypoint.sh deployer/entrypoint.sh scripts/*.sh \
    tests/run.sh tests/stubs/*/*
  docker run --rm -v "${REPO_ROOT}:/w:ro" -w /w "${HADOLINT_IMAGE}" \
    hadolint Dockerfile controller/Dockerfile deployer/Dockerfile tests/Dockerfile
  docker run --rm -v "${REPO_ROOT}:/repo:ro" -w /repo "${ACTIONLINT_IMAGE}" -color
  docker run --rm -v "${REPO_ROOT}:/repo:ro" "${ZIZMOR_IMAGE}" --offline /repo/.github/workflows
  docker compose --env-file .env.example config --no-env-resolution --quiet
}

case "${1:-all}" in
  all) lint; bash tests/run.sh ;;
  lint) lint ;;
  test) bash tests/run.sh ;;
  syntax) syntax ;;
  *) printf 'Usage: %s [all|lint|test|syntax]\n' "$0" >&2; exit 2 ;;
esac
