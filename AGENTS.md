# AGENTS.md — infra-runner

## Repository role

The controller manages disposable GitHub Actions runners through `controller-proxy`. It remains privileged through Docker API access; the runner user also belongs to the host Docker group. Isolating these paths is separate work. Job containers have no Docker socket and are destroyed after one job. Optional Kata isolates runner jobs further.

The `deployer` service is a read-only signature poller. It has no Docker CLI, `DOCKER_HOST`, socket/proxy network, server checkout, GitHub App key, plugin descriptors or environment file. It reads a public Ansible-owned target table and reports verification results through `/health`. Its status is observational and cannot command deployment.

The privileged host executor lives in `infra-ansible/roles/uye_deploy/`. It is installed from the Ansible control machine as root-owned code, target table and fixed Compose manifests. The systemd timer runs it once per minute with a lock. The executor independently resolves protected `main`, checks fast-forward history, SHA and latest tag agreement, the exact cosign identity and issuer, and the image revision label before pulling by digest. It updates only allowlisted services, validates running image ID and health, and writes root-owned state only after success. On a post-update health failure it restores the previous signed digest and reports the failed update.

## Changes

- Never run `git commit` or `git push`. The user handles commits in every repository.
- Preserve the user's branch and worktree. On this migration, work in the separate `codex/deployer-isolation` worktree.
- Update executor code, target table and manifests in `infra-ansible`; do not execute code from `/home/ghrunner/*` in the root process.
- Do not restore `deployer-proxy`, generic hooks, `env_file: .env`, checkout mounts or plugin overlays. `deployer/PLUGINS.md` records their retirement.
- A poller compromise must not create containers or read server secrets. Test the Compose configuration and image contents for this boundary.
- Keep the controller's proxy and runner pool behavior intact. Changes to their Docker rights require a separate isolation design.
- Release images carry the `org.opencontainers.image.revision` label. CI checks and security scan finish before `:latest` promotion. A signed SHA tag alone does not authorize deployment.

## Checks

Run `python3 -m unittest discover -s tests -p 'test_*.py'`, `docker compose config --quiet`, and `bash scripts/verify.sh all` in an environment with a Docker daemon. The Bats suite tests controller and release helper behavior. Run Ansible syntax and lint checks in `infra-ansible`. No uncommitted work is a published GHCR release; no local check is a server cutover.
