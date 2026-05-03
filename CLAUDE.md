# CLAUDE.md — infra-runner

Developer reference for AI assistants working in this repository.

---

## What this repo is

A hardened self-hosted GitHub Actions runner for **public repositories**. Each job runs in a
fresh, isolated container that is destroyed on completion — no state persists between jobs.
A GitOps deployer polls GHCR for new image digests and applies updates automatically;
no SSH push from CI is required.

---

## Repository layout

```
.
├── Dockerfile                        # runner image (ubuntu:24.04 + Docker CLI + Kaniko + GH runner binary)
├── entrypoint.sh                     # runner startup: accept token → config --ephemeral → run.sh
├── docker-compose.yml                # four services: two socket proxies + controller + deployer
├── .env.example                      # template for required env vars (copy → .env)
├── .gitignore
├── apparmor/
│   └── infra-runner                    # AppArmor profile applied to every runner container
├── controller/
│   ├── Dockerfile                    # controller image (ubuntu:24.04 + docker-ce-cli + jq + openssl + uuidgen)
│   └── entrypoint.sh                 # pool manager: spawn/teardown ephemeral runners
├── deployer/
│   ├── Dockerfile                    # deployer image (ubuntu:24.04 + docker-ce-cli + compose + cosign + python3)
│   ├── entrypoint.sh                 # GitOps loop: verify sig → pull → docker compose up -d
│   └── health_server.py              # minimal Python HTTP server for GET /health
├── scripts/
│   ├── ghcr-login.sh                 # refresh GHCR credentials on the host (sources github-app-token.sh; run before docker compose pull)
│   ├── github-app-token.sh           # GitHub App JWT helper (sourced by controller + deployer): RS256 JWT → installation token
│   ├── logging.sh                    # shared structured JSON log() function (sourced by controller + deployer)
│   ├── setup-apparmor.sh             # one-time: install + load AppArmor profile
│   └── setup-egress-policy.sh        # one-time: configure Docker address pool + iptables egress rules
├── seccomp/
│   └── runner-profile.json           # seccomp deny-list: blocks kernel-escape syscalls
└── .github/
    ├── dependabot.yml                # weekly PRs for Docker image + Actions version updates
    └── workflows/
        └── deploy.yml                # CI: build + push + cosign-sign runner/controller/deployer images
```

---

## Architecture

```
docker-compose (172.20.0.0/24 service space)
│
├── controller-proxy  (tecnativa/docker-socket-proxy — 172.20.0.0/26)
│   └── /var/run/docker.sock:ro  ← filters API; EXEC + BUILD disabled
│
├── controller  (infra-runner-controller — 172.20.0.64/26)
│   ├── DOCKER_HOST=tcp://controller-proxy:2375  ← no direct socket mount
│   └── env: GITHUB_APP_* (or GITHUB_TOKEN fallback), GITHUB_ORG, RUNNER_IMAGE, pool/limit settings
│
├── deployer-proxy  (tecnativa/docker-socket-proxy — 172.20.128.0/26)
│   └── /var/run/docker.sock:ro  ← same API filtering
│
└── deployer  (uye-deployer — 172.20.128.64/26)
    ├── DOCKER_HOST=tcp://deployer-proxy:2375  ← no direct socket mount
    ├── ./:/workspace:ro  ← reads docker-compose.yml + .env for docker compose up
    └── :HEALTH_PORT  ← GET /health endpoint

Per job — created by controller, destroyed after job completes:
├── runner-net-{id}     isolated bridge network (10.89.x.x/24, egress-restricted)
└── runner-job-{id}     ephemeral runner (Kaniko binary for image builds)
```

The runner container has no Docker socket and no privileged flag. Image builds use
**Kaniko**, which builds Docker images from a Dockerfile entirely in userspace without
a daemon or a privileged container. The controller's GitHub credential (App installation
token or PAT) never enters runner containers — runners receive only a short-lived
registration token.

---

## Environment variables

Loaded from `.env` (via `env_file` in Compose).

**Authentication** — exactly one of the following two paths must be configured:

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `GITHUB_APP_ID` | App path | — | Numeric GitHub App ID |
| `GITHUB_APP_INSTALLATION_ID` | App path | — | Numeric installation ID (org-level install) |
| `GITHUB_APP_PRIVATE_KEY_PATH` | App path | — | Container path to the PEM key (mounted `:ro`) |
| `GITHUB_TOKEN` | PAT path | — | Classic PAT fallback: `admin:org`, `manage_runners:org`, `read:packages` |

If `GITHUB_TOKEN` is set it is used as-is and the `GITHUB_APP_*` vars are ignored. If it is unset all three `GITHUB_APP_*` vars are required. The controller mints a short-lived installation access token at startup and refreshes it every 55 minutes.

**All other variables:**

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `GITHUB_ORG` | yes | — | GitHub org slug (e.g. `acme`) |
| `GITHUB_REPO` | no | `infra-runner` | Repo name; used to construct cosign certificate identity |
| `RUNNER_LABELS` | no | `self-hosted,linux,x64` | Comma-separated runner labels |
| `DESIRED_IDLE` | no | `2` | Warm idle runners to keep ready at all times |
| `RUNNER_MEMORY` | no | `4g` | Memory limit per runner container |
| `RUNNER_CPUS` | no | `2` | CPU limit per runner container |
| `RUNNER_KANIKO_SIZE` | no | `5g` | tmpfs size for `/kaniko` scratch space inside runner |
| `RUNNER_APPARMOR_PROFILE` | no | `infra-runner` | AppArmor profile name; empty to disable |
| `RUNNER_SECCOMP_HOST_PATH` | no | — | Absolute **host** path to `seccomp/runner-profile.json`; Docker daemon resolves it on the host, not inside any container |
| `COMPOSE_PROJECT_NAME` | yes | `infra-runner` | Must match the server directory name |
| `POLL_INTERVAL` | no | `60` | Deployer digest check interval (seconds) |
| `HEALTH_PORT` | no | `8080` | Deployer health endpoint port |
| `CONTROLLER_POLL_INTERVAL` | no | `15` | Controller pool maintenance cycle interval (seconds) |

**Vault integration** (all optional; enable by activating `docker-compose.vault.yml` overlay):

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `VAULT_COMPOSE_DIR` | yes (vault) | — | Absolute host path to infra-vault checkout |
| `VAULT_CERT_IDENTITY` | yes (vault) | — | cosign cert identity for vault-unseal CI workflow |
| `VAULT_TOKEN` | yes (vault) | — | Vault operator token for policy sync (stays on server) |
| `VAULT_ADDR` | no | `http://vault:8200` | Vault address reachable on vault-net |
| `VAULT_NET` | no | `vault-net` | Docker network Vault is on |
| `VAULT_UNSEAL_IMAGE` | no | `ghcr.io/${GITHUB_ORG}/vault-unseal:latest` | Full image ref to watch |
| `COMPOSE_FILE` | vault activation | `docker-compose.yml` | Set to `docker-compose.yml:docker-compose.vault.yml` to add vault workspace mount |

`RUNNER_IMAGE` and `DOCKER_HOST` are set in the Compose `environment` block (not `.env`)
and must not be overridden there.

`RUNNER_SECCOMP_HOST_PATH` must be a path on the **host** filesystem because Docker daemon
resolves it there. Leave empty to fall back to Docker's default seccomp profile.

---

## Dockerfile details (runner image)

- **Base**: `ubuntu:24.04`
- **Build args**: `RUNNER_VERSION` (default `2.334.0`) and `RUNNER_SHA256` (SHA256 of the tarball).
  Both must be updated together when bumping the runner — see *Updating the runner binary* below.
- **Docker CLI**: `docker-ce-cli` only — no daemon. Used for `docker login` (writes registry
  credentials to `~/.docker/config.json`). `docker build`/`run`/`push` have no daemon to reach.
- **Kaniko**: `COPY --from=gcr.io/kaniko-project/executor:v1.24.0 /kaniko/executor /usr/local/bin/kaniko`
  — statically linked binary, version-pinned so Dependabot tracks updates. Workflows call
  `kaniko` instead of `docker build && docker push`.
- **Runner binary**: downloaded from `github.com/actions/runner/releases`, SHA256-verified
  before extraction, then extracted to `/opt/actions-runner/`.
- **User**: root — required by Kaniko to extract image layers and execute `RUN` instructions.
  Container-level controls (seccomp, AppArmor, resource limits, no Docker socket, ephemeral)
  are the security boundary.
- **Entrypoint**: `entrypoint.sh`

---

## entrypoint.sh walkthrough (runner image)

```
1. Validate GITHUB_ORG and RUNNER_REGISTRATION_TOKEN are set.
   GITHUB_TOKEN is NOT present — the controller never passes it to runners.
2. ./config.sh --url … --token … --name … --labels … --unattended --ephemeral
3. exec ./run.sh   ← PID 1; exits after exactly one job
```

`--ephemeral` marks the runner as single-use. After `run.sh` picks up one job it
deregisters automatically and exits. No signal trap needed.

---

## controller/entrypoint.sh walkthrough

```
Startup:
  1. Validate env vars.
     Auth path A (preferred): GITHUB_APP_ID + GITHUB_APP_INSTALLATION_ID + GITHUB_APP_PRIVATE_KEY_PATH
       → source scripts/github-app-token.sh
       → acquire_github_token(): RS256 JWT → POST /app/installations/{id}/access_tokens → GITHUB_TOKEN
     Auth path B (fallback): GITHUB_TOKEN set directly → used as-is, App flow skipped
  2. GHCR login (PAT path only):
       Write {"auths":{"ghcr.io":{"auth":"<base64>"}}} directly to /root/.docker/config.json
       App path: skipped — App installation tokens cannot access GHCR; packages must be public
  3. Clean up orphaned resources from any previous controller run (label: runner-managed=true).
  4. docker pull RUNNER_IMAGE  ← pre-pull so the first spawn doesn't block.

Main loop (every CONTROLLER_POLL_INTERVAL seconds, default 15):
  5. maybe_refresh_github_token()  ← no-op on PAT path; refreshes token at 55 min on App path
                                      (no GHCR re-login on refresh — App path never logs in to GHCR)
  6. cleanup_exited_runners()  ← find exited runner containers, tear down job-{id} resources
  7. count_active_runners()    ← running containers with runner-role=runner label
  8. spawn (DESIRED_IDLE - active) new runners in background

spawn_runner():
  a. uuidgen → job_id (10 lowercase hex chars)
  b. docker network create runner-net-{id}  (bridge, labelled runner-managed=true)
  c. POST /orgs/{org}/actions/runners/registration-token → short-lived token
  d. docker run -d runner image → runner-job-{id}
       --name runner-job-{id}
       --network runner-net-{id}
       --memory --cpus
       [--security-opt seccomp=RUNNER_SECCOMP_HOST_PATH]
       [--security-opt apparmor=RUNNER_APPARMOR_PROFILE]
       --label runner-managed=true  --label runner-job-id={id}  --label runner-role=runner
       -e GITHUB_ORG -e RUNNER_REGISTRATION_TOKEN -e RUNNER_NAME -e RUNNER_LABELS
       --tmpfs /tmp:rw,nosuid,size=1g
       --tmpfs /root:rw,nosuid,size=512m      (docker login credentials, runner config)
       --tmpfs /kaniko:rw,nosuid,size=RUNNER_KANIKO_SIZE  (Kaniko layer scratch space)

cleanup_job(job_id):
  docker rm -f runner-job-{id}
  docker network rm runner-net-{id}
```

Logging: structured JSON to stdout (`ts`, `level`, `svc`, `msg`, plus contextual fields).
All per-job resources carry labels `runner-managed=true` and `runner-job-id={id}`.

---

## deployer/entrypoint.sh walkthrough

```
Startup:
  Auth path A (preferred): GITHUB_APP_ID + GITHUB_APP_INSTALLATION_ID + GITHUB_APP_PRIVATE_KEY_PATH
    → source scripts/github-app-token.sh
    → acquire_github_token(): RS256 JWT → POST /app/installations/{id}/access_tokens → GITHUB_TOKEN
  Auth path B (fallback): GITHUB_TOKEN set directly → used as-is, App flow skipped
  GHCR login (PAT path only):
    Write {"auths":{"ghcr.io":{"auth":"<base64>"}}} directly to /root/.docker/config.json
    App path: skipped — App installation tokens cannot access GHCR; packages must be public
  1. Start health_server.py in background (serves GET /health from /tmp/health)
  2. set_healthy()  ← write {"status":"ok","ts":"..."} to /tmp/health
  3. Log startup info (JSON)

Poll loop (every POLL_INTERVAL seconds):

  0. maybe_refresh_github_token()  ← no-op on PAT path; refreshes token at 55 min on App path
                                      (no GHCR re-login — App path never authenticates to GHCR)

  1. Self-update:
     pull_if_new(deployer:latest)  ← compare local digest before/after pull
     If new image downloaded:
       verify_image(deployer:latest)  ← cosign verify, keyless, OIDC-anchored
       If verified: docker compose up -d --no-deps deployer; exit 0
         (compose recreates this container; restart: unless-stopped brings it back)
       If NOT verified: set_unhealthy; skip

  2. Controller update:
     pull_if_new(controller:latest)
     If new:
       verify_image(controller:latest)
       If verified: docker compose up -d --no-deps controller
       If compose fails: set_unhealthy
       If NOT verified: set_unhealthy; skip

  3. Runner image:
     verify_image(runner:latest)  ← checks remote registry sig WITHOUT pulling first
     If verified: docker pull runner:latest (quiet)
       If pull fails: log warn + set_unhealthy; skip set_healthy this cycle
       (controller uses locally cached image on next spawn — never blocked on a pull)
     If NOT verified: set_unhealthy; local cache untouched

  4. vault-unseal image (only when _VAULT_ENABLED=true):
     pull_if_new(VAULT_UNSEAL_IMAGE)
     If new image downloaded:
       verify_image(VAULT_UNSEAL_IMAGE, VAULT_CERT_IDENTITY)  ← separate cert identity
       If verified: docker compose --project-name infra-vault \
                      --project-directory /workspace-vault up -d --no-deps vault-unseal
       If compose fails: set_unhealthy
       If NOT verified: set_unhealthy; skip

  5. Vault policy sync (every cycle, idempotent; skipped if VAULT_TOKEN unset):
     docker run --rm --network VAULT_NET hashicorp/vault:1.17
       (short-lived container on vault-net — Docker resolves bind-mount path on the HOST)
       For each vault/policies/*.hcl: vault policy write <name> <file>
     Failure is logged as a warning (Vault may be sealed); does NOT set_unhealthy

  6. set_healthy()  ← clears any transient error state from this cycle
       Skipped if runner image pull failed (preserves unhealthy state)

  7. sleep POLL_INTERVAL
```

`verify_image(image [cert_identity])` calls `cosign verify --certificate-identity <cert_identity> --certificate-oidc-issuer <token.actions.githubusercontent.com>`.
The second argument defaults to `$CERT_IDENTITY` (infra-runner's own workflow identity) when omitted.
vault-unseal passes `$VAULT_CERT_IDENTITY` explicitly (infra-vault's workflow identity).
Signature failures are immediately written to `/tmp/health` (atomically via `.tmp` + `mv`) and logged at `error` level.
Pull failures are logged as warnings and set the health endpoint to unhealthy.

---

## docker-compose.yml details

**Socket proxies** (`controller-proxy`, `deployer-proxy`)
- Image: `tecnativa/docker-socket-proxy@sha256:1f3a6...`
- Each mounts `/var/run/docker.sock:ro` and exposes port `2375` on an internal network
- Allowed API groups: `CONTAINERS`, `NETWORKS`, `IMAGES`, `AUTH`, `POST`, `DELETE`, `INFO`
- Deployer proxy additionally allows: `VOLUMES`
- Disabled on both: `EXEC=0`, `BUILD=0`, `PLUGINS=0`, `SYSTEM=0`, `SWARM=0`, `SECRETS=0`
- Resource limits: `memory: 128m`, `cpus: 0.25` — prevents a runaway proxy from affecting the host
- `restart: unless-stopped`

**controller service**
- Connects via `DOCKER_HOST=tcp://controller-proxy:2375` — no direct socket mount
- `depends_on: controller-proxy`
- `restart: unless-stopped`
- `tmpfs: /root/.docker` — GHCR credentials written here (ephemeral, never touches overlay fs)
- `volumes: ./seccomp/runner-profile.json:/home/ghrunner/infra-runner/seccomp/runner-profile.json:ro`
- `healthcheck`: `docker ps --filter label=runner-managed=true` every 30s

**deployer service**
- Connects via `DOCKER_HOST=tcp://deployer-proxy:2375` — no direct socket mount
- Mounts `./:/workspace:ro` for `docker compose up` (reads compose file + `.env`)
- Exposes `HEALTH_PORT` for the health endpoint
- `depends_on: deployer-proxy`
- `restart: unless-stopped`
- `tmpfs: /root/.docker` — GHCR credentials written here (ephemeral, never touches overlay fs)
- `healthcheck`: `GET /health` every 30s — compose can detect and restart a wedged deployer

**Networks** (all within 172.20.0.0/24, outside the 10.89.0.0/16 runner pool):
- `controller-proxy-net`: 172.20.0.0/26 — controller-proxy ↔ controller only
- `controller-net`: 172.20.0.64/26 — controller egress (internet, GitHub API)
- `deployer-proxy-net`: 172.20.128.0/26 — deployer-proxy ↔ deployer only
- `deployer-net`: 172.20.128.64/26 — deployer egress (internet, GHCR)

**No named volumes** — the controller creates no volumes in the current architecture.

**`docker-compose.vault.yml`** — optional overlay (activated by setting `COMPOSE_FILE` in `.env`).
Extends the deployer service with `${VAULT_COMPOSE_DIR}:/workspace-vault:ro` so the deployer can
run `docker compose --project-directory /workspace-vault up -d vault-unseal`. The base
`docker-compose.yml` is unchanged; vault integration is strictly opt-in.

---

## CI workflow (`.github/workflows/deploy.yml`)

Triggered on push to `main`. Runs on GitHub-hosted runners. All `uses:` action references
are pinned to full commit SHAs (not version tags) to prevent supply-chain substitution.
Dependabot sends update PRs when new versions are released.

```
1. actions/checkout@<sha>          (v6.0.2)
2. sigstore/cosign-installer@<sha> (v4.1.1, push events only)
3. docker/login-action@<sha>       (v4.1.0, push events only) → ghcr.io
4. docker/build-push-action@<sha>  (v7.1.0)
     build-push runner image     (context: .)
     build-push controller image (context: ., dockerfile: controller/Dockerfile)
     build-push deployer image   (context: ., dockerfile: deployer/Dockerfile)
     → each image: ghcr.io/{org}/{name}:{latest,sha}
5. cosign sign (push events only):
     cosign sign --yes --registry-username $GITHUB_ACTOR --registry-password $GITHUB_TOKEN \
       runner@{digest}
     cosign sign --yes --registry-username $GITHUB_ACTOR --registry-password $GITHUB_TOKEN \
       controller@{digest}
     cosign sign --yes --registry-username $GITHUB_ACTOR --registry-password $GITHUB_TOKEN \
       deployer@{digest}
     (keyless — signature is tied to this workflow's GitHub Actions OIDC identity)
```

On `pull_request` events: images are built but not pushed and not signed (login and
cosign steps are skipped). Fork PRs cannot push to GHCR.

**Build context**: all three images use `.` (repo root) as the build context. The
controller and deployer Dockerfiles copy `scripts/logging.sh` from the root before
copying their own entrypoints.

No SSH secrets are needed. Remove `DEPLOY_HOST`, `DEPLOY_USER`, `DEPLOY_SSH_KEY`
from repo secrets if previously set.

---

## First-time server setup

```bash
# 1. Create dedicated user
sudo useradd -m -s /bin/bash ghrunner
sudo usermod -aG docker ghrunner

# 2. Run one-time setup scripts (as root)
sudo bash ~/infra-runner/scripts/setup-egress-policy.sh
sudo systemctl restart docker   # activates the Docker address pool change
sudo bash ~/infra-runner/scripts/setup-apparmor.sh
# Verify: aa-status | grep infra-runner

# 3. Clone and configure (as ghrunner)
sudo -iu ghrunner
git clone https://github.com/YOUR_ORG/infra-runner ~/infra-runner
cd ~/infra-runner
cp .env.example .env
$EDITOR .env   # required: GITHUB_ORG, COMPOSE_PROJECT_NAME
               # auth (pick one): GITHUB_APP_ID + GITHUB_APP_INSTALLATION_ID + GITHUB_APP_PRIVATE_KEY_PATH
               #              or: GITHUB_TOKEN (classic PAT, backward compat)
               # recommended: RUNNER_SECCOMP_HOST_PATH

# 4. Start
# GitHub App path: packages must be public — no GHCR auth needed for `docker compose pull`.
# PAT path with private images: run `bash scripts/ghcr-login.sh` before pulling.
docker compose pull      # pulls controller-proxy, deployer-proxy, controller, deployer
docker compose up -d

# 5. Verify
docker compose logs -f controller | jq .
# → {"level":"info","svc":"controller","msg":"Runner is live","job_id":"..."}
```

### Required GitHub setting

**Settings → Actions → General → Fork pull request workflows →
"Require approval for all outside collaborators"**

This prevents PR workflows from unknown contributors from queuing at all.

---

## Day-to-day operations

```bash
# Follow logs (JSON — pipe through jq for readability)
docker compose logs -f controller | jq .
docker compose logs -f deployer   | jq .

# Check health endpoint
curl -s http://localhost:8080/health | jq .

# List all live per-job containers
docker ps --filter label=runner-managed=true

# Respawn runners (e.g. after changing RUNNER_LABELS or limits in .env)
docker compose restart controller

# Full teardown — in-progress jobs are interrupted
docker compose down

# Local build + start (after code changes in this repo)
docker compose build
docker compose up -d
```

---

## Updating the runner binary

Bump both `ARG RUNNER_VERSION` and `ARG RUNNER_SHA256` in `Dockerfile`, then push to `main`.
CI rebuilds all three images; the deployer verifies and applies the update within `POLL_INTERVAL` seconds.

```dockerfile
ARG RUNNER_VERSION=2.335.0   # ← bump here
ARG RUNNER_SHA256=<sha256>   # ← get from the release page (see below)
```

Find the SHA256 for `actions-runner-linux-x64-<version>.tar.gz` in the release body at
https://github.com/actions/runner/releases — each release lists checksums inline.
The build will fail at `sha256sum -c` if the hash does not match, catching supply-chain issues.

---

## GitHub PAT scopes required

**Must use a classic token.** Fine-grained PATs do not support `manage_runners:org`.

Create at: **github.com/settings/tokens → Tokens (classic)**

| Scope | Why |
|---|---|
| `manage_runners:org` | Register/deregister org-level runners |
| `admin:org` | Required alongside `manage_runners:org` |
| `read:packages` | Pull runner image from GHCR (if package is private) |

The `GITHUB_TOKEN` used in the CI workflow (built-in) only needs `packages: write`
(granted automatically). It is a different token from the PAT in `.env`.

---

## Security notes

- **No privileged containers in the job path.** Kaniko builds images in userspace without
  `--privileged`. The DinD host-escape vector is eliminated entirely.
- **The controller's GitHub credential never enters runner containers.** The controller
  holds either a GitHub App installation token (preferred, auto-refreshed every 55 min) or
  a static PAT. Runners receive only a short-lived registration token that expires after one use.
- **`--ephemeral` ensures single-use.** Even if a job attempts to persist a backdoor in
  the container filesystem, the container is destroyed before any subsequent job runs.
- **Docker socket proxies** (`tecnativa/docker-socket-proxy@sha256:1f3a6...`) sit between each service
  and `/var/run/docker.sock`. Controller and deployer connect via `DOCKER_HOST=tcp://proxy:2375`.
  `EXEC` and `BUILD` are disabled on both proxies — these are the primary escape vectors.
  The proxy containers themselves still mount the raw socket (unavoidable); they are minimal,
  versioned, and tracked by Dependabot.
- **Seccomp** blocks kernel-level syscalls (`mount`, `kexec_*`, `bpf`, kernel modules)
  that are the basis of most container escape techniques.
- **AppArmor profile** (`apparmor/infra-runner`) is applied to every runner container via
  `--security-opt apparmor=infra-runner`. It denies dangerous capabilities (`sys_module`,
  `sys_admin`, `net_raw`), raw/packet sockets, writes to kernel tunables and sysfs, and
  access to host credential files. Load with `scripts/setup-apparmor.sh` before first start.
  Set `RUNNER_APPARMOR_PROFILE=` (empty) in `.env` to disable.
- **Runner binary SHA256 is verified at build time.** `ARG RUNNER_SHA256` is checked with
  `sha256sum -c` before extraction. A mismatch fails the Docker build immediately.
- **GitHub Actions in CI are SHA-pinned.** All `uses:` references in `deploy.yml` are pinned
  to full commit SHAs so a retag cannot silently change the code that builds or signs images.
  Dependabot tracks version bumps and sends PRs.
- **Resource limits** prevent crypto mining or denial-of-service against the host. Socket proxy
  containers are additionally limited to `memory: 128m` / `cpus: 0.25`.
- **Network egress is restricted.** `scripts/setup-egress-policy.sh` allocates job networks
  from `10.89.0.0/16` and adds iptables `DOCKER-USER` rules allowing only DNS (53) and
  HTTPS (443) from that subnet. Private RFC 1918 ranges are explicitly blocked.
- **Image signatures.** CI signs all three images (runner, controller, deployer) with cosign
  keyless signing tied to the workflow's GitHub Actions OIDC identity. The deployer verifies
  every image signature before pulling or applying. A verification failure immediately sets
  the health endpoint to `503` and skips the update.
- **Workflow `GITHUB_TOKEN` scope must be minimised in downstream workflows.** Declare a
  `permissions:` block in every workflow, and set the org-level default to read-only at
  **Settings → Actions → General → Workflow permissions**.
- **Structured JSON logging.** Both controller and deployer emit newline-delimited JSON
  (`ts`, `level`, `svc`, `msg`, plus contextual fields). Pipe through `jq` or ingest with
  any log aggregator that reads Docker container logs.
- **Health endpoint.** `GET :<HEALTH_PORT>/health` returns `200 {"status":"ok","ts":"..."}` during
  normal operation and `503 {"status":"unhealthy","reason":"...","ts":"..."}` after a signature
  verification failure or compose error. Poll with UptimeRobot, Grafana, etc.
- **The `.env` file and any mounted PEM key contain secrets — both are gitignored. Never commit them.**
- **Remaining open threats:** proxy containers have full socket access (mitigated by being
  minimal and versioned); `$GITHUB_WORKSPACE` disk is unconstrained.
