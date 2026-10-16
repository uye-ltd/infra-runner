# infra-runner

A self-hosted GitHub Actions runner pool for public repositories. The controller creates disposable job containers. The `deployer` service observes signed image releases and serves `/health`; a separate Ansible-installed host executor applies releases.

## Deployment boundary

```text
GitHub main + GHCR
  ├─ deployer poller → signature status and /health only
  └─ systemd timer → root-owned uye-deploy executor → fixed Compose services
```

The poller has no Docker socket, Docker proxy route, Docker CLI, host checkout, plugin mounts, server `.env`, Vault token or GitHub App key. It cannot ask the executor to start a container. Its status is useful to operators, but the executor verifies the release independently. `infra-ansible/roles/uye_deploy/` owns the code, allowlist, Compose manifests, secret layout and timer.

The executor reads the current `main` SHA, requires forward history relative to its accepted SHA, checks that signed SHA and `latest` tags resolve to the same digest, verifies the exact workflow identity and Sigstore issuer, and checks the OCI revision label. It pulls only `repo@sha256:...`, rechecks the release before Compose, and updates only fixed services. On failed health after an update it restores the previously signed digest and records an error. Release state is accepted only after health and fixed post-deploy operations succeed. Missing images, signatures, registry or GitHub errors leave existing containers in place.

`controller-proxy`, Portainer's proxy and membership of `ghrunner` in the Docker group are remaining paths to host-level Docker rights. This migration isolates only the poller. Docker API access can create containers with host bind mounts, even behind an endpoint-filtering socket proxy.

## Layout

- `controller/`: pool manager using the controller Docker proxy.
- `deployer/`: Dockerless Python poller and HTTP health server.
- `docker-compose.yml`: controller, controller proxy and poller. No deployer proxy.
- `scripts/`: local bootstrap, promotion, runner egress and Kata utilities.
- `tests/`: Bats controller/helper tests and Python poller/health tests.
- `infra-ansible/roles/uye_deploy/` in the sibling repository: privileged release executor.

## Releases

`deploy.yml` runs checks, builds images with commit revision labels, signs digests and promotes the same digests to `:latest` only after security scanning. A protected `main` branch and public GHCR packages are required. CI has no SSH or deploy credentials. An image tag or poller report alone never grants deployment.

For a server migration, run the Ansible read-only audit, prepare the executor with its timer stopped, verify current Compose labels/networks/volumes and signed release candidates, then use `playbooks/deployer-cutover.yml`. That playbook stops the legacy deployer before the executor touches managed services, transfers them one at a time, removes the obsolete proxy and overlay settings, and enables the timer. `playbooks/postgres.yml` is separate and may run only after the new release is published and the cutover has passed. Never run the historical Postgres registration playbook.

If a release fails validation, the existing service stays running. On a post-update health failure, the executor attempts a signed digest restore. If the cutover itself fails, leave the timer stopped and repair the executor through Ansible; do not re-enable the legacy proxy. Backup data before an explicit operator rollback.

## Local checks

```bash
GITHUB_ORG=uye-ltd COMPOSE_PROJECT_DIR=/home/ghrunner/infra-runner docker compose config --quiet
python3 -m unittest discover -s tests -p 'test_*.py'
bash scripts/verify.sh all    # requires a local Docker daemon
```

For controller, Kata, Buildah and egress implementation details, see `controller/entrypoint.sh`, `scripts/setup-kata.sh`, `scripts/setup-egress-policy.sh`, `Dockerfile`, and the tests. The poller does not implement the retired plugin interface; see `deployer/PLUGINS.md`.
